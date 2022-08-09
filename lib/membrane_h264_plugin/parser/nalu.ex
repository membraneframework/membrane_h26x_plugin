defmodule Membrane.H264.Parser.NALu do
  @moduledoc false
  alias Membrane.H264.Parser.NALuPayload
  alias Membrane.H264.Parser.Schemes

  # See https://yumichan.net/video-processing/video-compression/introduction-to-h264-nal-unit/xw

  def parse(payload, state \\ %{__global__: %{}}) do
    {nalus, state} =
      payload
      |> extract_nalus
      |> Enum.map_reduce(state, fn nalu, state ->
        {nalu_start_in_bytes, nalu_size_in_bytes} = nalu.unprefixed_poslen
        nalu_start = nalu_start_in_bytes * 8

        <<_beggining::size(nalu_start), nalu_payload::binary-size(nalu_size_in_bytes),
          _rest::bitstring>> = payload

        {state, _rest_of_nalu_payload} =
          NALuPayload.parse_with_scheme(nalu_payload, Schemes.NALu.scheme(), state)

        state_without_global =
          state |> Enum.filter(fn {key, _value} -> key != :__global__ end) |> Map.new()

        new_state = %{__global__: state.__global__}
        {Map.put(nalu, :parsed_fields, state_without_global), new_state}
      end)

    nalus =
      nalus
      |> Enum.map(fn nalu ->
        Map.put(nalu, :type, NALuPayload.nalu_types()[nalu.parsed_fields.nal_unit_type])
      end)

    {nalus, state}
  end

  defp extract_nalus(payload) do
    payload
    |> :binary.matches([<<0, 0, 0, 1>>, <<0, 0, 1>>])
    |> Enum.chunk_every(2, 1, [{byte_size(payload), nil}])
    |> Enum.map(fn [{from, prefix_len}, {to, _}] ->
      len = to - from
      %{prefixed_poslen: {from, len}, unprefixed_poslen: {from + prefix_len, len - prefix_len}}
    end)
  end
end
