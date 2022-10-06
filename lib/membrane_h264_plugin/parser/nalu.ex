defmodule Membrane.H264.Parser.NALu do
  @moduledoc """
  A module defining a struct representing a single NAL unit.
  """
  use Bunch.Access

  @typedoc """
  A type defining the structure of a single NAL unit produced
  by the parser.
  """
  @type t :: %{
          parsed_fields: %{atom() => any()},
          prefix_length: pos_integer(),
          type: atom(),
          payload: binary(),
          pts: non_neg_integer() | nil,
          dts: non_neg_integer() | nil,
          status: :valid | :error
        }

  @enforce_keys [:payload, :prefix_length, :status]
  defstruct @enforce_keys ++ [:type, :parsed_fields, :pts, :dts]
end
