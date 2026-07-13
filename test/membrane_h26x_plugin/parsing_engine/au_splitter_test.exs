defmodule Membrane.H26x.ParsingEngine.AUSplitterTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Membrane.{H264, H265}
  alias Membrane.H26x.NALu
  alias Membrane.H26x.ParsingEngine.{AUSplitter, NALuParser, NALuSplitter}

  defp parse(payload, nalu_parser_impl, au_splitter_impl) do
    {nalus_payloads, _nalu_splitter} = NALuSplitter.split(payload, true, NALuSplitter.new())

    {nalus, _nalu_parser} =
      NALuParser.parse_nalus(nalu_parser_impl, nalus_payloads, NALuParser.new())

    {aus, _au_splitter} = AUSplitter.split(au_splitter_impl, nalus, true, AUSplitter.new())
    aus
  end

  defp au_lengths(aus) do
    for au <- aus,
        do:
          Enum.reduce(au, 0, fn %{payload: payload, stripped_prefix: prefix}, acc ->
            byte_size(payload) + byte_size(prefix) + acc
          end)
  end

  describe "H.264" do
    # These values were obtained with the use of FFmpeg
    @h264_au_lengths_ffmpeg %{
      "10-720a" => [777, 146, 93, 136],
      "10-720p" => [
        25_699,
        19_043,
        14_379,
        14_281,
        14_761,
        18_702,
        14_735,
        13_602,
        12_094,
        17_228
      ]
    }

    test "if the access unit lenghts parsed by access unit splitter are the same as access units lengths parsed by FFMPEG" do
      for {name, expected_lengths} <- @h264_au_lengths_ffmpeg do
        binary = File.read!("test/fixtures/h264/input-#{name}.h264")
        aus = parse(binary, H264.NALuParser, H264.AUSplitter)

        assert au_lengths(aus) == expected_lengths
      end
    end

    test "IDR frame split into two NALus" do
      # first frame of output of MP4 depayloader from Big Buck Bunny trailer
      fixture =
        <<0, 0, 0, 1, 39, 66, 224, 21, 169, 24, 60, 17, 253, 96, 13, 65, 128, 65, 173, 183, 160,
          15, 72, 15, 85, 239, 124, 4, 0, 0, 0, 1, 40, 222, 9, 136, 0, 0, 0, 1, 6, 0, 7, 131, 97,
          235, 0, 0, 3, 0, 64, 128, 0, 0, 0, 1, 6, 5, 17, 3, 135, 244, 78, 205, 10, 75, 220, 161,
          148, 58, 195, 212, 155, 23, 31, 3, 128, 0, 0, 0, 1, 37, 184, 32, 32, 255, 255, 252, 61,
          20, 0, 4, 21, 189, 247, 223, 125, 247, 223, 125, 247, 223, 125, 247, 223, 125, 247, 223,
          125, 247, 223, 125, 247, 223, 125, 245, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215,
          93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93,
          117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117,
          215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215,
          93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93,
          117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117,
          215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215,
          93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93,
          117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 224, 0, 0, 0, 1, 37, 0, 128, 56, 32, 32,
          255, 255, 252, 61, 20, 0, 4, 21, 189, 247, 223, 125, 247, 223, 125, 247, 223, 125, 247,
          255, 255, 240, 244, 80, 0, 16, 86, 247, 223, 125, 247, 223, 125, 247, 223, 125, 247,
          223, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215,
          93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93,
          117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117,
          215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215,
          93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93,
          117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117,
          215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 215, 93, 117, 255, 252, 126, 8,
          2, 152, 28, 64, 32, 172, 183, 223, 125, 247, 223, 125, 247, 223, 125, 247, 223, 125,
          247, 223, 125, 247, 223, 125, 247, 223, 125, 247, 224>>

      assert [au] = parse(fixture, H264.NALuParser, H264.AUSplitter)

      assert au
             |> Enum.map(&(byte_size(&1.payload) + byte_size(&1.stripped_prefix)))
             |> Enum.sum() == byte_size(fixture)
    end
  end

  @idr_parsed_fields %{
    nal_unit_type: 5,
    nal_ref_idc: 1,
    first_mb_in_slice: 0,
    frame_num: 0,
    pic_parameter_set_id: 0,
    field_pic_flag: 0,
    bottom_field_flag: 0,
    pic_order_cnt_type: 2,
    idr_pic_id: 0
  }

  describe "H.264 resync after an improper transition" do
    test "NALus following an improper NALu before the first VCL NALu are not dropped" do
      nalus = [
        nalu(:end_of_seq, %{nal_unit_type: 10}),
        nalu(:sps, %{nal_unit_type: 7}),
        nalu(:pps, %{nal_unit_type: 8}),
        nalu(:idr, @idr_parsed_fields)
      ]

      {aus, _au_splitter} = AUSplitter.split(H264.AUSplitter, nalus, true, AUSplitter.new())

      assert [[%NALu{type: :sps}, %NALu{type: :pps}, %NALu{type: :idr}]] = aus
    end

    test "NALus following an improper NALu inside an access unit are not dropped" do
      nalus = [
        nalu(:sps, %{nal_unit_type: 7}),
        nalu(:pps, %{nal_unit_type: 8}),
        nalu(:idr, @idr_parsed_fields),
        nalu(:sps_extension, %{nal_unit_type: 13}),
        nalu(:idr, %{@idr_parsed_fields | first_mb_in_slice: 8160})
      ]

      {aus, _au_splitter} = AUSplitter.split(H264.AUSplitter, nalus, true, AUSplitter.new())

      assert [[%NALu{type: :sps}, %NALu{type: :pps}, %NALu{type: :idr}, %NALu{type: :idr}]] =
               aus
    end
  end

  describe "H.265" do
    # These values were obtained with the use of FFmpeg
    @h265_au_lengths_ffmpeg %{
      "10-1920x1080" => [10_117, 493, 406, 447, 428, 320, 285, 297, 306, 296],
      "10-480x320-mainstillpicture" => [
        35_114,
        8824,
        8790,
        8762,
        8757,
        8766,
        8731,
        8735,
        8699,
        8710
      ]
    }

    test "if the access unit lenghts parsed by access unit splitter are the same as access units lengths parsed by FFMPEG" do
      for {name, expected_lengths} <- @h265_au_lengths_ffmpeg do
        binary = File.read!("test/fixtures/h265/input-#{name}.h265")
        aus = parse(binary, H265.NALuParser, H265.AUSplitter)

        assert au_lengths(aus) == expected_lengths
      end
    end
  end

  defp nalu(type, parsed_fields) do
    %NALu{
      type: type,
      parsed_fields: parsed_fields,
      stripped_prefix: <<0, 0, 1>>,
      payload: <<>>,
      status: :valid
    }
  end
end
