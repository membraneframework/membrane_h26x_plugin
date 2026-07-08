defmodule Membrane.H26x.Support.Common do
  @moduledoc false

  alias Membrane.{H264, H265}
  alias Membrane.H26x.ParsingEngine.{AUSplitter, NALuParser, NALuSplitter}

  @spec prepare_h264_buffers(
          binary,
          :au | :bytestream | :nalu,
          Membrane.H26x.ParsingEngine.stream_structure(),
          boolean()
        ) :: list

  def prepare_h264_buffers(
        binary,
        alignment,
        output_stream_structure \\ :annexb,
        stable_reprefixing? \\ true
      )

  def prepare_h264_buffers(binary, :bytestream, _output_stream_structure, _stable_reprefixing?) do
    do_prepare_bytestream_buffers(binary)
  end

  def prepare_h264_buffers(binary, alignment, output_stream_structure, stable_reprefixing?) do
    do_prepare_buffers(
      binary,
      alignment,
      output_stream_structure,
      stable_reprefixing?,
      H264.NALuParser,
      H264.AUSplitter
    )
  end

  @spec prepare_h265_buffers(
          binary,
          :au | :bytestream | :nalu,
          Membrane.H26x.ParsingEngine.stream_structure(),
          boolean()
        ) :: list

  def prepare_h265_buffers(
        binary,
        alignment,
        output_stream_structure \\ :annexb,
        stable_reprefixing? \\ true
      )

  def prepare_h265_buffers(binary, :bytestream, _output_stream_structure, _stable_reprefixing?) do
    do_prepare_bytestream_buffers(binary)
  end

  def prepare_h265_buffers(binary, alignment, output_stream_structure, stable_reprefixing?) do
    do_prepare_buffers(
      binary,
      alignment,
      output_stream_structure,
      stable_reprefixing?,
      H265.NALuParser,
      H265.AUSplitter
    )
  end

  defp do_prepare_bytestream_buffers(binary) do
    buffers =
      :binary.bin_to_list(binary) |> Enum.chunk_every(400) |> Enum.map(&:binary.list_to_bin(&1))

    Enum.map(buffers, &%Membrane.Buffer{payload: &1})
  end

  defp do_prepare_buffers(
         binary,
         alignment,
         output_stream_structure,
         stable_reprefixing?,
         nalu_parser_mod,
         au_splitter_mod
       ) do
    {nalus_payloads, _nalu_splitter} = NALuSplitter.split(binary, true, NALuSplitter.new(:annexb))

    {nalus, _nalu_parser} =
      NALuParser.parse_nalus(nalu_parser_mod, nalus_payloads, NALuParser.new())

    {aus, _au_splitter} = AUSplitter.split(au_splitter_mod, nalus, true, AUSplitter.new())

    case alignment do
      :nalu ->
        Enum.map_reduce(aus, 0, fn au, ts ->
          {Enum.map(au, fn nalu ->
             nalu_payload =
               NALuParser.get_prefixed_nalu_payload(
                 nalu,
                 output_stream_structure,
                 stable_reprefixing?
               )

             %Membrane.Buffer{payload: nalu_payload, pts: ts, dts: ts}
           end), ts + 1}
        end)
        |> elem(0)
        |> List.flatten()

      :au ->
        Enum.map_reduce(aus, 0, fn au, ts ->
          {%Membrane.Buffer{
             payload:
               Enum.map_join(au, fn nalu ->
                 NALuParser.get_prefixed_nalu_payload(
                   nalu,
                   output_stream_structure,
                   stable_reprefixing?
                 )
               end),
             pts: ts,
             dts: ts
           }, ts + 1}
        end)
        |> elem(0)
    end
  end
end
