defmodule Membrane.H264.ModesTest do
  use ExUnit.Case

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions

  alias Membrane.Buffer
  alias Membrane.H264.Parser
  alias Membrane.H264.Parser.{AUSplitter, NALuParser, NALuSplitter}
  alias Membrane.Testing.{Pipeline, Sink}

  @h264_input_file "test/fixtures/input-10-720p.h264"
  defp prepare_buffers(binary, :bytestream) do
    buffers =
      :binary.bin_to_list(binary) |> Enum.chunk_every(400) |> Enum.map(&:binary.list_to_bin(&1))

    Enum.map(buffers, &%Membrane.Buffer{payload: &1})
  end

  defp prepare_buffers(binary, :nalu_aligned) do
    {nalus_payloads, nalu_splitter} = NALuSplitter.split(binary, NALuSplitter.new())
    {last_nalu_payload, _nalu_splitter} = NALuSplitter.flush(nalu_splitter)
    nalus_payloads = nalus_payloads ++ [last_nalu_payload]

    {nalus, _nalu_parser} =
      Enum.map_reduce(nalus_payloads, NALuParser.new(), &NALuParser.parse(&1, &2))

    {aus, au_splitter} = nalus |> AUSplitter.split(AUSplitter.new())
    {last_au, _au_splitter} = AUSplitter.flush(au_splitter)
    aus = aus ++ [last_au]

    Enum.map_reduce(aus, 0, fn au, ts ->
      {for(nalu <- au, do: %Membrane.Buffer{payload: nalu.payload, pts: ts, dts: ts}), ts + 1}
    end)
    |> elem(0)
    |> Enum.flat_map(& &1)
  end

  defp prepare_buffers(binary, :au_aligned) do
    {nalus_payloads, nalu_splitter} = NALuSplitter.split(binary, NALuSplitter.new())
    {last_nalu_payload, _nalu_splitter} = NALuSplitter.flush(nalu_splitter)
    nalus_payloads = nalus_payloads ++ [last_nalu_payload]

    {nalus, _nalu_parser} =
      Enum.map_reduce(nalus_payloads, NALuParser.new(), &NALuParser.parse(&1, &2))

    {aus, au_splitter} = nalus |> AUSplitter.split(AUSplitter.new())
    {last_au, _au_splitter} = AUSplitter.flush(au_splitter)
    aus = aus ++ [last_au]

    Enum.map_reduce(aus, 0, fn au, ts ->
      {%Membrane.Buffer{payload: Enum.map_join(au, & &1.payload), pts: ts, dts: ts}, ts + 1}
    end)
    |> elem(0)
  end

  defmodule ModeTestSource do
    use Membrane.Source

    def_options mode: []

    def_output_pad :output,
      demand_mode: :auto,
      mode: :push,
      accepted_format:
        any_of(
          %Membrane.RemoteStream{type: :bytestream},
          %Membrane.H264.RemoteStream{alignment: alignment} when alignment in [:au, :nalu]
        )

    @impl true
    def handle_init(_ctx, opts) do
      {[], %{mode: opts.mode}}
    end

    @impl true
    def handle_parent_notification(actions, _ctx, state) do
      {actions, state}
    end

    @impl true
    def handle_playing(_ctx, state) do
      stream_format =
        case state.mode do
          :bytestream -> %Membrane.RemoteStream{type: :bytestream}
          :nalu_aligned -> %Membrane.H264.RemoteStream{alignment: :nalu}
          :au_aligned -> %Membrane.H264.RemoteStream{alignment: :au}
        end

      {[stream_format: {:output, stream_format}], state}
    end
  end

  test "if the pts and dts are set to nil in :bytestream mode" do
    binary = File.read!(@h264_input_file)
    mode = :bytestream
    input_buffers = prepare_buffers(binary, mode)

    {:ok, _supervisor_pid, pid} =
      Pipeline.start_supervised(
        structure: [
          child(:source, %ModeTestSource{mode: mode})
          |> child(:parser, Parser)
          |> child(:sink, Sink)
        ]
      )

    assert_pipeline_play(pid)
    send_buffers_actions = for buffer <- input_buffers, do: {:buffer, {:output, buffer}}
    Pipeline.message_child(pid, :source, send_buffers_actions ++ [end_of_stream: :output])

    output_buffers = prepare_buffers(binary, :au_aligned)

    Enum.each(output_buffers, fn buf ->
      payload = buf.payload
      assert_sink_buffer(pid, :sink, %Buffer{payload: ^payload, pts: nil, dts: nil})
    end)

    Pipeline.terminate(pid, blocking?: true)
  end

  test "if the pts and dts are rewritten properly in :nalu_aligned mode" do
    binary = File.read!(@h264_input_file)
    mode = :nalu_aligned
    input_buffers = prepare_buffers(binary, mode)

    {:ok, _supervisor_pid, pid} =
      Pipeline.start_supervised(
        structure: [
          child(:source, %ModeTestSource{mode: mode})
          |> child(:parser, Parser)
          |> child(:sink, Sink)
        ]
      )

    assert_pipeline_play(pid)
    send_buffers_actions = for buffer <- input_buffers, do: {:buffer, {:output, buffer}}
    Pipeline.message_child(pid, :source, send_buffers_actions ++ [end_of_stream: :output])

    output_buffers = prepare_buffers(binary, :au_aligned)

    Enum.each(output_buffers, fn buf ->
      payload = buf.payload
      pts = buf.pts
      dts = buf.dts
      assert_sink_buffer(pid, :sink, %Buffer{payload: ^payload, pts: ^pts, dts: ^dts})
    end)

    Pipeline.terminate(pid, blocking?: true)
  end

  test "if the pts and dts are rewritten properly in :au_aligned mode" do
    binary = File.read!(@h264_input_file)
    mode = :au_aligned
    input_buffers = prepare_buffers(binary, mode)

    {:ok, _supervisor_pid, pid} =
      Pipeline.start_supervised(
        structure: [
          child(:source, %ModeTestSource{mode: mode})
          |> child(:parser, Parser)
          |> child(:sink, Sink)
        ]
      )

    assert_pipeline_play(pid)
    send_buffers_actions = for buffer <- input_buffers, do: {:buffer, {:output, buffer}}
    Pipeline.message_child(pid, :source, send_buffers_actions ++ [end_of_stream: :output])

    output_buffers = input_buffers

    Enum.each(output_buffers, fn buf ->
      payload = buf.payload
      pts = buf.pts
      dts = buf.dts
      assert_sink_buffer(pid, :sink, %Buffer{payload: ^payload, pts: ^pts, dts: ^dts})
    end)

    Pipeline.terminate(pid, blocking?: true)
  end
end
