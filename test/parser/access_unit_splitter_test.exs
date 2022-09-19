defmodule AccessUnitSplitterTest do
  @moduledoc false

  use ExUnit.Case

  alias Membrane.H264.FFmpeg.Parser.Native, as: NativeParser

  @test_files_names ["10-720a", "10-720p"]
  defmodule FullBinaryParser do
    @moduledoc false
    alias Membrane.H264.Parser.{
      AccessUnitSplitter,
      NALu,
      NALuSplitter,
      NALuTypes,
      SchemeParser
    }

    alias Membrane.H264.Parser.SchemeParser.{Schemes, State}

    @spec parse(binary(), State.t()) :: AccessUnitSplitter.access_unit_t()
    def parse(payload, state \\ %State{__local__: %{}, __global__: %{}}) do
      {nalus, _state} =
        payload
        |> NALuSplitter.extract_nalus(nil, nil, nil, nil, false)
        |> Enum.map_reduce(state, fn nalu, state ->
          prefix_length = nalu.prefix_length

          <<_prefix::binary-size(prefix_length), nalu_header::binary-size(1), nalu_body::binary>> =
            nalu.payload

          new_state = SchemeParser.State.new(state)

          {header_parsed_fields, state} =
            SchemeParser.parse_with_scheme(nalu_header, Schemes.NALuHeader.scheme(), new_state)

          type = NALuTypes.get_type(header_parsed_fields.nal_unit_type)

          {full_nalu_parsed_fields, state} = parse_proper_nalu_type(nalu_body, state, type)

          {%NALu{nalu | parsed_fields: full_nalu_parsed_fields, type: type}, state}
        end)

      {_nalus, _buffer, _state, _previous_primary_coded_picture_nalu, aus} =
        AccessUnitSplitter.split_nalus_into_access_units(nalus)

      aus
    end

    defp parse_proper_nalu_type(payload, state, type) do
      case type do
        :sps ->
          SchemeParser.parse_with_scheme(payload, Schemes.SPS.scheme(), state)

        :pps ->
          SchemeParser.parse_with_scheme(payload, Schemes.PPS.scheme(), state)

        :idr ->
          SchemeParser.parse_with_scheme(payload, Schemes.Slice.scheme(), state)

        :non_idr ->
          SchemeParser.parse_with_scheme(payload, Schemes.Slice.scheme(), state)

        _unknown_nalu_type ->
          {%{}, state}
      end
    end
  end

  test "if the access unit lenghts parsed by access unit splitter are the same as access units lengths parsed by FFMPEG" do
    file_names = Enum.map(@test_files_names, fn name -> "test/fixtures/input-#{name}.h264" end)

    for file_name <- file_names do
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
