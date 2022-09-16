defmodule Membrane.H264.Parser.SchemeParser.State do
  @moduledoc """
  This module defines a structure which holds the state
  of the scheme parser.
  """
  use Bunch.Access

  @typedoc """
  A type defining the state of the scheme parser.

  The parser preserves its state in the map, which
  consists of two parts:
  * a map under the `:__global__` key - it contains information
    fetched from a NALu, which might be needed during the parsing
    of the following NALus.
  * a map under the `:__local__` key -  it holds information valid
    during a time of a single NALu processing, and it's cleaned
    after the NALu is completly parsed.
  All information fetched from binary part is put into the
  `:__local__` map. If some information needs to be available when
  other binary part is parsed, it needs to be stored in the map under
  the `:__global__` key of the parser's state, which can be done i.e.
  with the `save_as_global_state` statements of the scheme syntax.
  """
  @opaque t :: %__MODULE__{__global__: map(), __local__: map()}

  @enforce_keys [:__global__, :__local__]
  defstruct @enforce_keys

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
end
