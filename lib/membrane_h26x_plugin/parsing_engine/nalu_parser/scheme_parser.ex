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
  @type parse_result :: {:ok, payload(), t()} | {:error, t()}

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
    scheme = scheme_module.scheme()
    defaults_map = Map.new(scheme_module.defaults())
    state = Map.update!(state, :__local__, &Map.merge(defaults_map, &1))

    case do_parse_with_scheme({<<>>, payload}, scheme, state, iterators) do
      {:error, state} -> {:error, state}
      {:ok, _remaining_payload, state} -> {:ok, get_local_state(state), state}
    end
  end

  # The payload is threaded as `{unescaped_bits, escaped_rest}` and unescaped
  # one chunk at a time, because schemes read only a short header of a NALu
  # while slices are kilobytes long.
  @type payload :: {bitstring(), binary()}
  @chunk_bytes 64
  # u64, or ue with 32 leading zeros, is the most a single field can consume
  @max_field_bits 65

  defp ensure_chunk({bits, <<>>} = payload) when is_bitstring(bits), do: payload

  defp ensure_chunk({bits, _escaped} = payload) when bit_size(bits) >= @max_field_bits,
    do: payload

  defp ensure_chunk({bits, escaped}) do
    {chunk, escaped} = split_chunk(escaped)
    {<<bits::bitstring, unescape(chunk)::binary>>, escaped}
  end

  defp split_chunk(escaped) when byte_size(escaped) <= @chunk_bytes + 2, do: {escaped, <<>>}

  # An emulation prevention sequence must not straddle two chunks, so trailing
  # zero bytes are left for the next chunk.
  defp split_chunk(escaped) do
    size =
      case escaped do
        <<_head::binary-size(@chunk_bytes - 2), 0, 0, _rest::binary>> -> @chunk_bytes - 2
        <<_head::binary-size(@chunk_bytes - 1), 0, _rest::binary>> -> @chunk_bytes - 1
        _other -> @chunk_bytes
      end

    <<chunk::binary-size(^size), rest::binary>> = escaped
    {chunk, rest}
  end

  defp unescape(payload) do
    :binary.split(payload, <<0, 0, 3>>, [:global]) |> Enum.join(<<0, 0>>)
  end

  @spec do_parse_with_scheme(payload(), Scheme.t(), t(), list(integer())) :: parse_result()
  defp do_parse_with_scheme(payload, scheme, state, iterators) do
    reduce_directives(scheme, payload, state, fn directive, payload, state ->
      parse_directive(directive, payload, state, iterators)
    end)
  end

  # Threads the `payload`/`state` accumulator through `fun`, stopping as soon as
  # `fun` returns `{:error, state}`.
  @spec reduce_directives(Enumerable.t(), payload(), t(), (term(), payload(), t() ->
                                                             parse_result())) :: parse_result()
  defp reduce_directives(enum, payload, state, fun) do
    Enum.reduce_while(enum, {:ok, payload, state}, fn elem, {:ok, payload, state} ->
      case fun.(elem, payload, state) do
        {:ok, payload, state} -> {:cont, {:ok, payload, state}}
        {:error, state} -> {:halt, {:error, state}}
      end
    end)
  end

  @spec parse_directive(Scheme.directive(), payload(), t(), list(integer())) :: parse_result()
  defp parse_directive({:field, {name, type}}, payload, state, iterators) do
    {bits, escaped} = ensure_chunk(payload)
    {field_value, bits} = parse_field(bits, state, type)
    {:ok, {bits, escaped}, put_local(state, [name | iterators], field_value)}
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
    {:ok, payload, put_local(state, [name], value)}
  end

  defp parse_directive({:execute, function}, payload, state, _iterators)
       when is_function(function, 1) do
    case function.(state) do
      {:ok, state} -> {:ok, payload, state}
      {:error, state} -> {:error, state}
    end
  end

  defp parse_directive({:execute, function}, {bits, escaped}, state, iterators) do
    case function.(<<bits::bitstring, unescape(escaped)::binary>>, state, iterators) do
      {:ok, bits, state} -> {:ok, {bits, <<>>}, state}
      {:error, state} -> {:error, state}
    end
  end

  defp parse_directive({:save_state_as_global_state, key_generator}, payload, state, _iterators) do
    {key_generating_function, args_list} = make_function(key_generator)
    key = apply(key_generating_function, get_args(args_list, state.__local__))
    {:ok, payload, put_global(state, [key], state.__local__)}
  end

  @spec run_conditionally(payload(), t(), Scheme.t(), value_provider(boolean())) ::
          parse_result()
  defp run_conditionally(payload, state, scheme, condition) do
    {condition_function, args_list} = make_function(condition)

    if apply(condition_function, get_args(args_list, state.__local__)),
      do: do_parse_with_scheme(payload, scheme, state, []),
      else: {:ok, payload, state}
  end

  @spec loop(payload(), t(), Scheme.t(), list(integer()), atom(), term(), term()) ::
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
      state = put_local(state, [iterator_name], iterator)
      do_parse_with_scheme(payload, scheme, state, previous_iterators ++ [iterator])
    end)
    |> case do
      {:ok, payload, state} ->
        {:ok, payload, delete_local(state, iterator_name)}

      {:error, state} ->
        {:error, state}
    end
  end

  defp get_args(args_names, state) do
    Enum.map(args_names, &Map.fetch!(state, &1))
  end

  @unsigned_field_sizes Map.new(1..64, &{:"u#{&1}", &1})

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
        how_many_bits = Map.fetch!(@unsigned_field_sizes, unsigned_int)
        <<value::unsigned-size(^how_many_bits), rest::bitstring>> = payload
        {value, rest}
    end
  end

  defp make_function({function, args}) when is_function(function), do: {function, args}
  defp make_function(value), do: {fn -> value end, []}

  defp put_local(state, path, value) do
    %{state | __local__: put_nested(state.__local__, path, value)}
  end

  defp delete_local(state, key), do: %{state | __local__: Map.delete(state.__local__, key)}

  defp put_global(state, path, value) do
    %{state | __global__: put_nested(state.__global__, path, value)}
  end

  defp put_nested(map, [key], value), do: Map.put(map, key, value)

  defp put_nested(map, [key | rest], value) do
    Map.put(map, key, put_nested(Map.get(map, key) || %{}, rest, value))
  end
end
