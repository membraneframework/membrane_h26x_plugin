defmodule Membrane.H264.Parser.NALuSplitter do
  @moduledoc """
  A module with functions responsible for splitting the h264 stream into the NAL units.
  The splitting is based on "Annex B" of the "ITU-T Rec. H.264 (01/2012)".
  """
  alias  Membrane.H264.Parser.NALu


  @doc """
  A function which takes a binary h264 stream as a input and produces a list of `NALu.t()` structures, with the `prefixed_poslen` and `unprefixed_poslen` fields
  set to the appropriate values, corresponding to the position of the NAL unit in the input binary.
  """
  @spec extract_nalus(binary()) :: [NALu.t()]
  def extract_nalus(payload) do
    payload
    |> :binary.matches([<<0, 0, 0, 1>>, <<0, 0, 1>>])
    |> Enum.chunk_every(2, 1, [{byte_size(payload), nil}])
    |> Enum.map(fn [{from, prefix_len}, {to, _}] ->
      len = to - from
      %NALu{prefixed_poslen: {from, len}, unprefixed_poslen: {from + prefix_len, len - prefix_len}}
    end)
  end
end
