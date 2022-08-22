defmodule Membrane.H264.Parser.State do
  @moduledoc """
  This module defines a structure which holds the state of the parser.
  """
  use Bunch.Access

  @typedoc """
  A type defining the state of the parser. The parser preserves its state in the map, which consists of two parts:
  * a map under the `:__global__` key - it contains information fetched from a NALu, which might be needed during the parsing of the following NALus.
  * a map under the `:__local__` key -  it holds information valid during a time of a single NALu processing, and it's cleaned after the NALu is
  completly parsed.
  All information fetched from NALu is put into the `:__local__` map.
  If some information needs to be available when other NALu is parsed, it needs to be stored in the map under the `:__global__` key of the parser's state, which
  can be done i.e. with the `save_as_global_state` statements of the scheme syntax.
  """
  @type t :: %__MODULE__{__global__: %{}, __local__: %{}}

  @enforce_keys [:__global__, :__local__]
  defstruct @enforce_keys
end
