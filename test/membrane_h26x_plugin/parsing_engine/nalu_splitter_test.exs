defmodule Membrane.H26x.ParsingEngine.NALuSplitterTest do
  use ExUnit.Case, async: true

  alias Membrane.H26x.ParsingEngine.NALuSplitter

  @nalus [<<0, 0, 0, 1, 1, 2, 3>>, <<0, 0, 1, 4, 5, 0>>, <<0, 0, 0, 1, 6, 0, 9>>, <<0, 0, 1, 7>>]
  @stream Enum.join(@nalus)

  defp split_chunks(chunks, structure) do
    {nalus, splitter} =
      Enum.flat_map_reduce(chunks, NALuSplitter.new(structure), fn chunk, splitter ->
        NALuSplitter.split(chunk, false, splitter)
      end)

    {last, _splitter} = NALuSplitter.split(<<>>, true, splitter)
    nalus ++ last
  end

  test "splits an Annex B stream regardless of the chunking" do
    for chunk_size <- 1..byte_size(@stream) do
      chunks = for <<chunk::binary-size(^chunk_size) <- @stream>>, do: chunk

      rest =
        binary_part(@stream, byte_size(Enum.join(chunks)), rem(byte_size(@stream), chunk_size))

      chunks = if rest == <<>>, do: chunks, else: chunks ++ [rest]
      assert split_chunks(chunks, :annexb) == @nalus
    end
  end

  test "holds back the last NALu until the next start code is seen" do
    assert {[<<0, 0, 0, 1, 1, 2, 3>>], splitter} =
             NALuSplitter.split(<<0, 0, 0, 1, 1, 2, 3, 0, 0, 1, 4>>, false, NALuSplitter.new())

    assert {[<<0, 0, 1, 4, 5>>], _splitter} = NALuSplitter.split(<<5>>, true, splitter)
  end

  test "drops the bytes preceding the first start code" do
    assert {[<<0, 0, 1, 1>>, <<0, 0, 1, 2>>], _splitter} =
             NALuSplitter.split(<<9, 9, 0, 0, 1, 1, 0, 0, 1, 2>>, true, NALuSplitter.new())
  end

  test "splits a length-prefixed stream regardless of the chunking" do
    nalus = [<<0, 0, 0, 3, 1, 2, 3>>, <<0, 0, 0, 1, 4>>, <<0, 0, 0, 2, 5, 6>>]
    stream = Enum.join(nalus)

    for chunk_size <- 1..byte_size(stream) do
      chunks = for <<chunk::binary-size(^chunk_size) <- stream>>, do: chunk
      rest = binary_part(stream, byte_size(Enum.join(chunks)), rem(byte_size(stream), chunk_size))
      chunks = if rest == <<>>, do: chunks, else: chunks ++ [rest]
      assert split_chunks(chunks, {:avc1, 4}) == nalus
    end
  end
end
