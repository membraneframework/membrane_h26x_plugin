defmodule AccessUnitSplitterTest do
  @moduledoc false

  use ExUnit.Case
  alias Membrane.H264.FFmpeg.Parser.Native, as: Parser

  test "if the access unit lenghts parsed by access unit splitter are the same as access units lengths parsed by FFMPEG" do
    dir_files = Path.wildcard("test/fixtures/*.h264")
    for file_name <- dir_files do
      binary = File.read!(file_name)
      aus = Membrane.H264.AccessUnitSplitter.split_binary_into_access_units(binary)
      au_lengths = for au <- aus, do: Enum.reduce(au, 0, fn nalu, acc -> (nalu.prefixed_poslen |> elem(1))+acc  end)

      {:ok, decoder_ref} = Parser.create()
      {:ok, au_lengths_ffmpeg, _decoding_order_numbers, _presentation_order_numbers, _changes} =
              Parser.parse(binary, decoder_ref)

      assert au_lengths==au_lengths_ffmpeg
    end
  end
end
