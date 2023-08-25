defmodule Membrane.H264.Parser.NALu do
  @moduledoc """
  A module defining a struct representing a single NAL unit.
  """

  @typedoc """
  A type defining the structure of a single NAL unit produced
  by the `Membrane.H264.Parser.NALuParser`.

  In the structure there ardqde following fields:
  * `parsed_fields` - the map with keys being the NALu field names and the values being the value fetched from the NALu binary.
  They correspond to the NALu schemes defined in the section *7.3.* of the *"ITU-T Rec. H.264 (01/2012)"*.
  * `stripped_prefix` - prefix that used to split the NAL units in the bytestream and was stripped from the payload.
  The prefix is defined as in: *"Annex B"* of the *"ISO/IEC 14496-10"* or in "ISO/IEC 14496-15".
  * `type` - an atom representing the type of the NALu. Atom's name is based on the
  *"Table 7-1 – NAL unit type codes, syntax element categories, and NAL unit type classes"* of the *"ITU-T Rec. H.264 (01/2012)"*.
  * `payload` - the binary, which parsing resulted in that structure being produced stripped of it's prefix
  * `status` - `:valid`, if the parsing was successfull, `:error` otherwise
  """
  @type t :: %__MODULE__{
          parsed_fields: %{atom() => any()},
          type: Membrane.H264.Parser.NALuTypes.nalu_type(),
          stripped_prefix: binary(),
          payload: binary(),
          status: :valid | :error,
          timestamps: timestamps()
        }

  @type timestamps :: {pts :: integer() | nil, dts :: integer() | nil}

  @enforce_keys [:parsed_fields, :type, :stripped_prefix, :payload, :status]
  defstruct @enforce_keys ++ [timestamps: {nil, nil}]
end
