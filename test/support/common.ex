defmodule Membrane.H264.Support.Common do
  @moduledoc false

  alias Membrane.H264.AUSplitter
  alias Membrane.H26x.{NALuParser, NALuSplitter}

  @spec prepare_buffers(
          binary,
          :au | :bytestream | :nalu,
          Membrane.H264.Parser.stream_structure(),
          boolean()
        ) :: list

  def prepare_buffers(
        binary,
        alignment,
        output_stream_structure \\ :annexb,
        stable_reprefixing? \\ true
      )

  def prepare_buffers(binary, :bytestream, _output_stream_structure, _stable_reprefixing?) do
    buffers =
      :binary.bin_to_list(binary) |> Enum.chunk_every(400) |> Enum.map(&:binary.list_to_bin(&1))

    Enum.map(buffers, &%Membrane.Buffer{payload: &1})
  end

  def prepare_buffers(binary, mode, output_stream_structure, stable_reprefixing?) do
    {nalus_payloads, _nalu_splitter} = NALuSplitter.split(binary, true, NALuSplitter.new(:annexb))

    {nalus, _nalu_parser} =
      NALuParser.parse_nalus(nalus_payloads, NALuParser.new())

    {aus, _au_splitter} = AUSplitter.split(nalus, true, AUSplitter.new())

    case mode do
      :nalu_aligned ->
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

      :au_aligned ->
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
