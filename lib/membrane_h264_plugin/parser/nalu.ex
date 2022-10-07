defmodule Membrane.H264.Parser.NALu do
  @moduledoc """
  A module defining a struct representing a single NAL unit.
  """
  use Bunch.Access

  @typedoc """
  A type defining the structure of a single NAL unit produced
  by the parser.
  """
  @type t :: %__MODULE__{
          parsed_fields: %{atom() => any()},
          prefix_length: pos_integer(),
          type: atom(),
          payload: binary(),
          status: :valid | :error
        }

  @enforce_keys [:parsed_fields, :prefix_length, :type, :payload, :status]
  defstruct @enforce_keys
end
