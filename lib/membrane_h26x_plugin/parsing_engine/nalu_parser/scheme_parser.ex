defmodule Membrane.H26x.ParsingEngine.NALuParser.SchemeParser do
  @moduledoc false
  # The module providing functions to parse the binary,
  # based on the given Scheme.

  use Bunch.Access

  alias Membrane.H26x.ParsingEngine.NALuParser.ExpGolombConverter
  alias Membrane.H26x.ParsingEngine.NALuParser.Scheme

  @typedoc """
  A type defining the state of the scheme parser.

  The parser preserves its state in the map, which
  consists of two parts:
  * a map under the `:__global__` key - it contains information
    fetched from a NALu, which might be needed during the parsing
    of the following NALus.
  * a map under the `:__local__` key -  it holds information valid
    during a time of a single NALu processing, and it's cleaned
    after the NALu is completely parsed.
  All information fetched from binary part is put into the
  `:__local__` map. If some information needs to be available when
  other binary part is parsed, it needs to be stored in the map under
  the `:__global__` key of the parser's state, which can be done i.e.
  with the `save_as_global_state` statements of the scheme syntax.
  """
  @opaque t :: %__MODULE__{__global__: map(), __local__: map()}

  @enforce_keys [:__global__, :__local__]
  defstruct @enforce_keys

  @typedoc """
  This type defines a value provider which provides values used in further
  processing of a parser.

  A value provider can be either a hardcoded value, known at the compilation
  time, or a tuple consisting of a lambda expression and the list of keys
  mapping to some values in the parser's state. If the value provider is a tuple,
  then it's first element - the lambda expression-  is invoked with the arguments
  being the values of the fields which are available in the parser's state under
  the key names given in the parser's state, and the value used in the further
  processing is the value returned by that lambda expression.
  """
  @type value_provider(return_type) :: return_type | {(... -> return_type), list(any())}

  @typedoc """
  A type describing the field types which can be used
  in NALu scheme definition.

  Defined as in: *"7.2 Specification of syntax functions, categories, and descriptors"*
  of the *"ITU-T Rec. H.264 (01/2012)"*.
  """
  @type field ::
          :u1
          | :u2
          | :u3
          | :u4
          | :u5
          | :u8
          | :u16
          | :u16
          | {:uv, value_provider(integer())}
          | :ue
          | :se

  @doc """
  Returns a new `SchemeParser.State` struct instance.

  The new state's `local` state is clear. If the `State` is provided
  as an argument, the new state's `__global__` state is copied from
  the argument. Otherwise, it is set to the clear state.
  """
  @spec new(t()) :: t()
  def new(old_state \\ %__MODULE__{__global__: %{}, __local__: %{}}) do
    %__MODULE__{__global__: old_state.__global__, __local__: %{}}
  end

  @doc """
  Returns the local part of the state.
  """
  @spec get_local_state(t()) :: map()
  def get_local_state(state) do
    state.__local__
  end

  @typedoc """
  The result of parsing a scheme directive (or a whole scheme): either the
  yet-unparsed `payload` with the updated state, or a failure carrying only the
  state gathered so far.
  """
  @type parse_result :: {:ok, payload :: bitstring(), t()} | {:error, t()}

  @doc """
  Parses the binary stream representing a NALu, based
   on the scheme definition.

  Removes the emulation prevention bytes (`<<0, 0, 3>>` sequences) from the
  payload before parsing.

  Returns `{:ok, parsed_fields, state}` with the information fetched from the
  NALu, or `{:error, state}` if parsing was aborted (the state still holds the
  fields parsed so far).
  """
  @spec parse_with_scheme(binary(), module(), t(), list(integer())) ::
          {:ok, map(), t()} | {:error, t()}
  def parse_with_scheme(
        payload,
        scheme_module,
        state \\ new(),
        iterators \\ []
      ) do
    # delete prevention emulation 3 bytes
    payload = :binary.split(payload, <<0, 0, 3>>, [:global]) |> Enum.join(<<0, 0>>)

    scheme = scheme_module.scheme()
    defaults_map = Map.new(scheme_module.defaults())
    state = Map.update!(state, :__local__, &Map.merge(defaults_map, &1))

    case do_parse_with_scheme(payload, scheme, state, iterators) do
      {:error, state} -> {:error, state}
      {:ok, _remaining_payload, state} -> {:ok, get_local_state(state), state}
    end
  end

  @spec do_parse_with_scheme(bitstring(), Scheme.t(), t(), list(integer())) :: parse_result()
  defp do_parse_with_scheme(payload, scheme, state, iterators) do
    reduce_directives(scheme, payload, state, fn directive, payload, state ->
      parse_directive(directive, payload, state, iterators)
    end)
  end

  # Threads the `payload`/`state` accumulator through `fun`, stopping as soon as
  # `fun` returns `{:error, state}`.
  @spec reduce_directives(Enumerable.t(), bitstring(), t(), (term(), bitstring(), t() ->
                                                               parse_result())) :: parse_result()
  defp reduce_directives(enum, payload, state, fun) do
    Enum.reduce_while(enum, {:ok, payload, state}, fn elem, {:ok, payload, state} ->
      case fun.(elem, payload, state) do
        {:ok, payload, state} -> {:cont, {:ok, payload, state}}
        {:error, state} -> {:halt, {:error, state}}
      end
    end)
  end

  @spec parse_directive(Scheme.directive(), bitstring(), t(), list(integer())) :: parse_result()
  defp parse_directive({:field, {name, type}}, payload, state, iterators) do
    {field_value, payload} = parse_field(payload, state, type)
    {:ok, payload, insert_into_parser_state(state, field_value, [:__local__, name] ++ iterators)}
  end

  defp parse_directive({:if, {condition, scheme}}, payload, state, _iterators) do
    run_conditionally(payload, state, scheme, condition)
  end

  defp parse_directive(
         {:for, {[iterator: iterator_name, from: min_value, to: max_value], scheme}},
         payload,
         state,
         iterators
       ) do
    loop(payload, state, scheme, iterators, iterator_name, min_value, max_value)
  end

  defp parse_directive({:calculate, {name, to_calculate}}, payload, state, _iterators) do
    {function, args_list} = make_function(to_calculate)
    value = apply(function, get_args(args_list, state.__local__))
    {:ok, payload, Bunch.Access.put_in(state, [:__local__, name], value)}
  end

  defp parse_directive({:execute, function}, payload, state, iterators) do
    function.(payload, state, iterators)
  end

  defp parse_directive({:save_state_as_global_state, key_generator}, payload, state, _iterators) do
    {key_generating_function, args_list} = make_function(key_generator)
    key = apply(key_generating_function, get_args(args_list, state.__local__))
    {:ok, payload, Bunch.Access.put_in(state, [:__global__, key], state.__local__)}
  end

  @spec run_conditionally(bitstring(), t(), Scheme.t(), value_provider(boolean())) ::
          parse_result()
  defp run_conditionally(payload, state, scheme, condition) do
    {condition_function, args_list} = make_function(condition)

    if apply(condition_function, get_args(args_list, state.__local__)),
      do: do_parse_with_scheme(payload, scheme, state, []),
      else: {:ok, payload, state}
  end

  @spec loop(bitstring(), t(), Scheme.t(), list(integer()), atom(), term(), term()) ::
          parse_result()
  defp loop(payload, state, scheme, previous_iterators, iterator_name, min_value, max_value) do
    {min_value, min_args_list} = make_function(min_value)
    {max_value, max_args_list} = make_function(max_value)

    {min_value, max_value} = {
      apply(min_value, get_args(min_args_list, state.__local__)),
      apply(max_value, get_args(max_args_list, state.__local__))
    }

    range = if min_value > max_value, do: [], else: min_value..max_value

    reduce_directives(range, payload, state, fn iterator, payload, state ->
      state = Bunch.Access.put_in(state, [:__local__, iterator_name], iterator)
      do_parse_with_scheme(payload, scheme, state, previous_iterators ++ [iterator])
    end)
    |> case do
      {:ok, payload, state} ->
        {:ok, payload, Bunch.Access.delete_in(state, [:__local__, iterator_name])}

      {:error, state} ->
        {:error, state}
    end
  end

  defp get_args(args_names, state) do
    Enum.map(args_names, &Map.fetch!(state, &1))
  end

  defp parse_field(payload, state, type) do
    case type do
      {:uv, lambda, args} ->
        size = apply(lambda, get_args(args, state.__local__))
        <<value::unsigned-size(^size), rest::bitstring>> = payload
        {value, rest}

      :ue ->
        ExpGolombConverter.to_integer(payload)

      :se ->
        ExpGolombConverter.to_integer(payload, negatives: true)

      unsigned_int ->
        how_many_bits =
          Atom.to_string(unsigned_int) |> String.slice(1..-1//1) |> String.to_integer()

        <<value::unsigned-size(^how_many_bits), rest::bitstring>> = payload
        {value, rest}
    end
  end

  defp make_function({function, args}) when is_function(function), do: {function, args}
  defp make_function(value), do: {fn -> value end, []}

  defp insert_into_parser_state(state, value, iterators_list, already_consumed_iterators \\ [])

  defp insert_into_parser_state(state, value, [], already_consumed_iterators) do
    Bunch.Access.put_in(state, already_consumed_iterators, value)
  end

  defp insert_into_parser_state(state, value, iterators_list, already_consumed_iterators) do
    [first | rest] = iterators_list
    to_insert = Bunch.Access.get_in(state, already_consumed_iterators ++ [first])
    to_insert = if to_insert == nil, do: %{}, else: to_insert
    state = Bunch.Access.put_in(state, already_consumed_iterators ++ [first], to_insert)
    insert_into_parser_state(state, value, rest, already_consumed_iterators ++ [first])
  end
end
