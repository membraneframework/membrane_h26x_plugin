defmodule Membrane.H265.AUSplitterTest do
  @moduledoc false

  use ExUnit.Case, async: true

  @test_files_names ["10-1920x1080", "10-480x320-mainstillpicture"]

  # These values were obtained with the use of FFmpeg
  @au_lengths_ffmpeg %{
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

  defmodule FullBinaryParser do
    @moduledoc false
    alias Membrane.H265.{AUSplitter, NALuParser}
    alias Membrane.H26x.NALuSplitter

    @spec parse(binary()) :: AUSplitter.access_unit_t()
    def parse(payload) do
      {nalus_payloads, _nalu_splitter} = NALuSplitter.split(payload, true, NALuSplitter.new())
      {nalus, _nalu_parser} = NALuParser.parse_nalus(nalus_payloads, NALuParser.new())
      {aus, _au_splitter} = AUSplitter.split(nalus, true, AUSplitter.new())
      aus
    end
  end

  test "if the access unit lenghts parsed by access unit splitter are the same as access units lengths parsed by FFMPEG" do
    for name <- @test_files_names do
      full_name = "test/fixtures/h265/input-#{name}.h265"
      binary = File.read!(full_name)

      aus = FullBinaryParser.parse(binary)

      au_lengths =
        for au <- aus,
            do:
              Enum.reduce(au, 0, fn %{payload: payload, stripped_prefix: prefix}, acc ->
                byte_size(prefix) + byte_size(payload) + acc
              end)

      assert au_lengths == @au_lengths_ffmpeg[name]
    end
  end
end
