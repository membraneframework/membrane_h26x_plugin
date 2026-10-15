defmodule Membrane.H26x.ParsingEngine.NALuParser.SchemeParser do
  @moduledoc false
  # The state of the scheme-based NALu parsing and the entry point for parsing a
  # NALu payload with a compiled scheme (see `Membrane.H26x.ParsingEngine.NALuParser.Scheme`).

  use Bunch.Access

  alias Membrane.H26x.ParsingEngine.NALuParser.Scheme

  @typedoc """
  A type defining the state of the scheme parser.

  The parser preserves its state in the struct, which
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
  with the `save_state_as_global_state` statements of the scheme syntax.
  """
  @opaque t :: %__MODULE__{__global__: map(), __local__: map()}

  @enforce_keys [:__global__, :__local__]
  defstruct @enforce_keys

  @emulation_prevention_bytes <<0, 0, 3>>

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

  @doc """
  Parses the binary stream representing a NALu, based on the scheme definition.

  Removes the emulation prevention bytes (`<<0, 0, 3>>` sequences) from the
  payload before parsing - only from as many leading bytes as the scheme can read
  (see the `max_bytes` option of the scheme).

  Returns `{:ok, parsed_fields, state}` with the information fetched from the
  NALu, or `{:error, state}` if parsing was aborted (the state still holds the
  fields parsed so far).
  """
  @spec parse_with_scheme(binary(), module(), t()) :: {:ok, map(), t()} | {:error, t()}
  def parse_with_scheme(payload, scheme_module, state \\ new()) do
    payload = remove_emulation_prevention(payload, scheme_module.max_bytes())

    case scheme_module.parse(payload, state) do
      {:ok, _remaining_payload, state} -> {:ok, state.__local__, state}
      {:error, state} -> {:error, state}
    end
  end

  @doc """
  Removes the emulation prevention bytes from the first `max_bytes` bytes of the payload,
  dropping the rest of the payload.
  """
  @spec remove_emulation_prevention(binary(), pos_integer() | :infinity) :: binary()
  def remove_emulation_prevention(payload, _max_bytes) when byte_size(payload) < 3, do: payload

  def remove_emulation_prevention(payload, max_bytes) do
    payload =
      if max_bytes != :infinity and byte_size(payload) > max_bytes,
        do: binary_part(payload, 0, max_bytes),
        else: payload

    case :binary.split(payload, @emulation_prevention_bytes, [:global]) do
      [payload] -> payload
      parts -> Enum.join(parts, <<0, 0>>)
    end
  end

  @doc """
  Runs an `execute` directive of a scheme, aborting the parsing on `{:error, state}`.
  """
  @spec execute(Scheme.execute(), bitstring(), map(), map(), [integer()]) ::
          {bitstring(), map(), map()}
  def execute(function, payload, local, global, iterators) do
    case function.(payload, %__MODULE__{__local__: local, __global__: global}, iterators) do
      {:ok, payload, %__MODULE__{__local__: local, __global__: global}} ->
        {payload, local, global}

      {:error, state} ->
        throw({:scheme_error, state})
    end
  end

  @doc """
  Stores the value of a field read inside `for` loops, keyed by the loop iterators.
  """
  @spec put_nested(map(), atom(), [integer()], term()) :: map()
  def put_nested(local, name, [iterator], value) do
    Map.update(local, name, %{iterator => value}, &Map.put(&1, iterator, value))
  end

  def put_nested(local, name, [iterator | rest], value) do
    nested = put_nested(Map.get(local, name, %{}), iterator, rest, value)
    Map.put(local, name, nested)
  end
end
