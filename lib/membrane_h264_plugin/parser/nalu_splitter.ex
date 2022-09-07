defmodule Membrane.H264.Parser.NALuSplitter do
  @moduledoc """
  A module with functions responsible for parsing of the binary stream and producing the NALu structures
  """

  @typedoc """
  A type defining the structure of a single NAL unit produced by the parser.
  """
  @type nalu_t :: %{
          parsed_fields: %{atom() => any()},
          prexifed_poslen: {integer(), integer()},
          type: atom(),
          unprefixed_poslen: {integer(), integer()}
        }

  def extract_nalus(payload) do
    payload
    |> :binary.matches([<<0, 0, 0, 1>>, <<0, 0, 1>>])
    |> Enum.chunk_every(2, 1, [{byte_size(payload), nil}])
    |> Enum.map(fn [{from, prefix_len}, {to, _}] ->
      len = to - from
      %{prefixed_poslen: {from, len}, unprefixed_poslen: {from + prefix_len, len - prefix_len}}
    end)
  end
end
