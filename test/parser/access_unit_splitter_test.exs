defmodule AccessUnitSplitterTest do
  @moduledoc false

  use ExUnit.Case

  alias Membrane.H264.FFmpeg.Parser.Native, as: NativeParser

  defmodule FullBinaryParser do
    @moduledoc false
    alias Membrane.H264.Parser.{
      AccessUnitSplitter,
      NALuSplitter,
      NALuTypes,
      SchemeParser
    }

    alias Membrane.H264.Parser.SchemeParser.{Schemes, State}

    @spec parse(binary(), State.t()) :: AccessUnitSplitter.access_unit_t()
    def parse(payload, state \\ %State{__local__: %{}, __global__: %{}}) do
      {nalus, _state} =
        payload
        |> NALuSplitter.extract_nalus(nil, nil, false)
        |> Enum.map_reduce(state, fn nalu, state ->
          prefix_length = nalu.prefix_length

          <<_prefix::binary-size(prefix_length), header_bits::binary-size(1),
            nalu_body_payload::bitstring>> = nalu.payload

          {_rest_of_nalu_payload, state} =
            SchemeParser.parse_with_scheme(header_bits, Schemes.NALuHeader.scheme(), state)

          {_rest_of_nalu_payload, state} = parse_proper_nalu_type(nalu_body_payload, state)

          new_state = %State{__global__: state.__global__, __local__: %{}}
          {Map.put(nalu, :parsed_fields, state.__local__), new_state}
        end)

      nalus =
        nalus
        |> Enum.map(fn nalu ->
          Map.put(nalu, :type, NALuTypes.get_type(nalu.parsed_fields.nal_unit_type))
        end)

      {_nalus, _buffer, _state, _previous_primary_coded_picture_nalu, aus} =
        AccessUnitSplitter.split_nalus_into_access_units(nalus)

      aus
    end

    defp parse_proper_nalu_type(payload, state) do
      case NALuTypes.get_type(state.__local__.nal_unit_type) do
        :sps ->
          SchemeParser.parse_with_scheme(payload, Schemes.SPS.scheme(), state)

        :pps ->
          SchemeParser.parse_with_scheme(payload, Schemes.PPS.scheme(), state)

        :idr ->
          SchemeParser.parse_with_scheme(payload, Schemes.Slice.scheme(), state)

        :non_idr ->
          SchemeParser.parse_with_scheme(payload, Schemes.Slice.scheme(), state)

        _unknown_nalu_type ->
          {payload, state}
      end
    end
  end

  test "if the access unit lenghts parsed by access unit splitter are the same as access units lengths parsed by FFMPEG" do
    dir_files = Path.wildcard("test/fixtures/*.h264")

    for file_name <- dir_files do
      binary = File.read!(file_name)

      aus = FullBinaryParser.parse(binary)

      au_lengths =
        for au <- aus,
            do:
              Enum.reduce(au, 0, fn %{payload: payload}, acc ->
                byte_size(payload) + acc
              end)

      {:ok, decoder_ref} = NativeParser.create()

      {:ok, au_lengths_ffmpeg, _decoding_order_numbers, _presentation_order_numbers, _changes} =
        NativeParser.parse(binary, decoder_ref)

      assert au_lengths == au_lengths_ffmpeg
    end
  end
end
