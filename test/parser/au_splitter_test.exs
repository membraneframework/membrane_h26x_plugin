defmodule AUSplitterTest do
  @moduledoc false

  use ExUnit.Case

  alias Membrane.H264.FFmpeg.Parser.Native, as: NativeParser

  @test_files_names ["10-720a", "10-720p"]
  defmodule FullBinaryParser do
    @moduledoc false
    alias Membrane.H264.Parser.{
      AUSplitter,
      NALuParser,
      NALuSplitter
    }

    @spec parse(binary()) :: AUSplitter.access_unit_t()
    def parse(payload) do
      nalu_splitter = NALuSplitter.new()
      {nalus_payloads, nalu_splitter} = NALuSplitter.split(payload, nalu_splitter)
      {last_nalu_payload, _nalu_splitter} = NALuSplitter.flush(nalu_splitter)
      nalus_payloads = nalus_payloads ++ [last_nalu_payload]

      nalu_parser = NALuParser.new()

      {nalus, _nalu_parser} =
        Enum.map_reduce(nalus_payloads, nalu_parser, &NALuParser.parse(&1, &2))

      {aus, _au_splitter} = AUSplitter.split_nalus(nalus, AUSplitter.new())

      aus
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
