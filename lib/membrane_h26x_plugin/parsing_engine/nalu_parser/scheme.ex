defmodule Membrane.H26x.ParsingEngine.NALuParser.Scheme do
  @moduledoc false
  # A NALu scheme describes the internal structure of a NALu: the fields which
  # need to be fetched from the binary. The syntax is designed to match the
  # syntax tables of the H26x specification documents. The scheme is compiled
  # into a `parse/2` function at compile time, so no interpretation happens
  # while parsing.
  #
  # Usage:
  #
  #     use Membrane.H26x.ParsingEngine.NALuParser.Scheme
  #
  #     defscheme defaults: [...], max_bytes: 64 do
  #       [
  #         field: {:name, :u8},
  #         ...
  #       ]
  #     end
  #
  # `defaults` are the initial values of the fields (overridden by the values
  # parsed from the binary), `max_bytes` is the upper bound of the number of
  # (unescaped) bytes the scheme can ever read, letting the parser skip the
  # emulation prevention removal for the rest of the NALu.
  #
  # The following statements are available:
  # * `field: {name, type}` - reads the appropriate number of bits, decodes the integer based on
  #   consumed bits and stores it under the given name in the parser's local state.
  #   Inside a `for` loop the value is stored in a map keyed by the loop iterator(s).
  # * `if: {condition, scheme}` - introduces conditional parsing: if the condition is fulfilled, the
  #   binary is parsed with the nested scheme.
  # * `for: {[iterator: name, from: from, to: to], scheme}` - parses the nested scheme for each
  #   value of the iterator, available under `name` in the local state while looping.
  # * `execute: function` - performs custom actions with the payload and the state (see
  #   `t:execute/0`), to be used for processing which cannot be expressed with the scheme syntax.
  # * `save_state_as_global_state: key` - saves the local state of the NALu being parsed in the
  #   `:__global__` part of the state, under the given key, making it available while
  #   parsing the following NALus.
  #
  # The conditions, loop bounds, `uv` field sizes and global state keys are value providers:
  # either a literal, or a `{function, [field_name]}` tuple, where the function is
  # called with the values of the given fields of the local state.
  #
  # The scheme passed to `defscheme` must be a literal list, built from literal lists
  # with `++` and calls to functions of other modules returning quoted sub-schemes
  # (the module body is expanded before it is evaluated, so neither module attributes
  # nor functions of the scheme module itself are available at that point).

  alias Membrane.H26x.ParsingEngine.NALuParser.{ExpGolombConverter, SchemeParser}

  @type value_provider(return_type) :: return_type | {(... -> return_type), [atom()]}

  @typedoc """
  Field types, defined as in *"7.2 Specification of syntax functions, categories, and descriptors"*
  of the *"ITU-T Rec. H.264 (01/2012)"*: `:uN` for an unsigned integer of `N` bits, `:uv` for
  an unsigned integer of a variable number of bits, `:ue` and `:se` for Exp-Golomb coded integers.
  """
  @type field_type :: atom() | {:uv, value_provider(non_neg_integer())}

  @type execute ::
          (bitstring(), SchemeParser.t(), [integer()] ->
             {:ok, bitstring(), SchemeParser.t()} | {:error, SchemeParser.t()})

  @callback parse(bitstring(), SchemeParser.t()) ::
              {:ok, rest :: bitstring(), SchemeParser.t()} | {:error, SchemeParser.t()}
  @callback max_bytes() :: pos_integer() | :infinity

  defmacro __using__(_opts) do
    quote do
      @behaviour unquote(__MODULE__)
      import unquote(__MODULE__), only: [defscheme: 1, defscheme: 2]
    end
  end

  defmacro defscheme(opts \\ [], do: scheme) do
    defaults = opts |> Keyword.get(:defaults, []) |> Map.new()
    max_bytes = Keyword.get(opts, :max_bytes, :infinity)
    body = scheme |> expand(__CALLER__) |> compile([])

    quote do
      @impl true
      def max_bytes(), do: unquote(max_bytes)

      @impl true
      def parse(payload, %SchemeParser{__local__: local, __global__: global}) do
        local = Map.merge(unquote(Macro.escape(defaults)), local)

        try do
          unquote(body)
          {:ok, payload, %SchemeParser{__local__: local, __global__: global}}
        catch
          {:scheme_error, state} -> {:error, state}
        end
      end
    end
  end

  defp expand(list, env) when is_list(list), do: Enum.map(list, &expand_directive(&1, env))
  defp expand({:++, _meta, [left, right]}, env), do: expand(left, env) ++ expand(right, env)

  defp expand({{:., _meta, [module, function]}, _meta2, args}, env) do
    module = Macro.expand(module, env)
    expand(apply(module, function, args), env)
  end

  defp expand(other, _env) do
    raise ArgumentError, "A scheme must be a literal list, got: #{Macro.to_string(other)}"
  end

  defp expand_directive({:if, {condition, scheme}}, env),
    do: {:if, {condition, expand(scheme, env)}}

  defp expand_directive({:for, {opts, scheme}}, env), do: {:for, {opts, expand(scheme, env)}}
  defp expand_directive(directive, _env), do: directive

  defp compile(directives, iterators) do
    {:__block__, [], Enum.map(directives, &compile_directive(&1, iterators))}
  end

  defp compile_directive({:field, {name, type}}, iterators) do
    quote do
      unquote(read_field(type))
      local = unquote(store_field(name, iterators))
    end
  end

  defp compile_directive({:if, {condition, scheme}}, iterators) do
    quote do
      {payload, local, global} =
        if unquote(provide(condition)) do
          unquote(compile(scheme, iterators))
          {payload, local, global}
        else
          {payload, local, global}
        end
    end
  end

  defp compile_directive({:for, {[iterator: name, from: from, to: to], scheme}}, iterators) do
    iterator = Macro.var(:"iterator#{length(iterators)}", __MODULE__)

    quote do
      from = unquote(provide(from))
      to = unquote(provide(to))

      {payload, local, global} =
        if from > to do
          {payload, local, global}
        else
          Enum.reduce(from..to, {payload, local, global}, fn unquote(iterator),
                                                             {payload, local, global} ->
            local = Map.put(local, unquote(name), unquote(iterator))
            unquote(compile(scheme, iterators ++ [iterator]))
            {payload, local, global}
          end)
        end

      local = Map.delete(local, unquote(name))
    end
  end

  defp compile_directive({:execute, function}, iterators) do
    quote do
      {payload, local, global} =
        SchemeParser.execute(unquote(function), payload, local, global, unquote(iterators))
    end
  end

  defp compile_directive({:save_state_as_global_state, key}, _iterators) do
    quote do
      global = Map.put(global, unquote(provide(key)), local)
    end
  end

  defp compile_directive(directive, _iterators) do
    raise ArgumentError, "Unknown scheme directive: #{Macro.to_string(directive)}"
  end

  defp read_field(:ue) do
    quote do
      {value, payload} = ExpGolombConverter.to_integer(payload)
    end
  end

  defp read_field(:se) do
    quote do
      {value, payload} = ExpGolombConverter.to_integer(payload, negatives: true)
    end
  end

  defp read_field({:{}, _meta, [:uv, function, args]}) do
    quote do
      size = unquote(provide({function, args}))
      <<value::unsigned-size(^size), payload::bitstring>> = payload
    end
  end

  defp read_field(type) when is_atom(type) do
    size =
      case Atom.to_string(type) do
        "u" <> bits -> String.to_integer(bits)
        _other -> raise ArgumentError, "Unknown field type: #{inspect(type)}"
      end

    quote do
      <<value::unsigned-size(unquote(size)), payload::bitstring>> = payload
    end
  end

  defp store_field(name, []) do
    quote do
      Map.put(local, unquote(name), value)
    end
  end

  defp store_field(name, iterators) do
    quote do
      SchemeParser.put_nested(local, unquote(name), unquote(iterators), value)
    end
  end

  defp provide({function, args}) when is_list(args) do
    fetches = Enum.map(args, fn arg -> quote(do: Map.fetch!(local, unquote(arg))) end)

    quote do
      unquote(function).(unquote_splicing(fetches))
    end
  end

  defp provide(literal), do: literal
end
