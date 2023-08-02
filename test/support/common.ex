defmodule Membrane.H264.Support.Common do
  @moduledoc false

  alias Membrane.H264.Parser.{AUSplitter, NALuParser, NALuSplitter}

  @spec prepare_buffers(
          binary,
          :au_aligned | :bytestream | :nalu_aligned,
          Membrane.H264.Parser.parsed_stream_type(),
          Membrane.H264.Parser.parsed_stream_type()
        ) :: list

  def prepare_buffers(
        binary,
        alignment,
        parsed_stream_type \\ :annexb,
        output_parsed_stream_type \\ :annexb,
        optimize_reprefixing? \\ true
      )

  def prepare_buffers(binary, :bytestream, _, _, _) do
    buffers =
      :binary.bin_to_list(binary) |> Enum.chunk_every(400) |> Enum.map(&:binary.list_to_bin(&1))

    Enum.map(buffers, &%Membrane.Buffer{payload: &1})
  end

  def prepare_buffers(
        binary,
        alignment,
        input_parsed_stream_type,
        output_parsed_stream_type,
        optimize_reprefixing?
      ) do
    {nalus_payloads, nalu_splitter} =
      NALuSplitter.split(binary, NALuSplitter.new(input_parsed_stream_type))

    {last_nalu_payload, _nalu_splitter} = NALuSplitter.flush(nalu_splitter)
    nalus_payloads = nalus_payloads ++ [last_nalu_payload]

    {nalus, _nalu_parser} =
      Enum.map_reduce(
        nalus_payloads,
        NALuParser.new(
          input_parsed_stream_type,
          output_parsed_stream_type,
          optimize_reprefixing?
        ),
        &NALuParser.parse(&1, &2)
      )

    {aus, au_splitter} = nalus |> AUSplitter.split(AUSplitter.new())
    {last_au, _au_splitter} = AUSplitter.flush(au_splitter)
    aus = aus ++ [last_au]

    case alignment do
      :nalu_aligned ->
        Enum.map_reduce(aus, 0, fn au, ts ->
          {for(nalu <- au, do: %Membrane.Buffer{payload: nalu.payload, pts: ts, dts: ts}), ts + 1}
        end)
        |> elem(0)
        |> List.flatten()

      :au_aligned ->
        Enum.map_reduce(aus, 0, fn au, ts ->
          {%Membrane.Buffer{payload: Enum.map_join(au, & &1.payload), pts: ts, dts: ts}, ts + 1}
        end)
        |> elem(0)
    end
  end
end
