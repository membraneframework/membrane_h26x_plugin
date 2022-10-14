defmodule Membrane.H264.ModesTest do
  use ExUnit.Case

  import Membrane.Testing.Assertions
  import Membrane.ParentSpec

  alias Membrane.Buffer
  alias Membrane.H264.Parser
  alias Membrane.H264.Parser.{AUSplitter, NALuParser, NALuSplitter}
  alias Membrane.Testing.{Pipeline, Sink}

  @h264_input_file "test/fixtures/input-10-720p.h264"
  defp prepare_buffers(binary, mode) when mode == :bytestream do
    buffers =
      :binary.bin_to_list(binary) |> Enum.chunk_every(400) |> Enum.map(&:binary.list_to_bin(&1))

    Enum.map(buffers, &%Membrane.Buffer{payload: &1})
  end

  defp prepare_buffers(binary, mode) when mode == :nalu_aligned do
    {nalus_payloads, nalu_splitter} = NALuSplitter.split(binary, NALuSplitter.new())
    {last_nalu_payload, _nalu_splitter} = NALuSplitter.flush(nalu_splitter)
    nalus_payloads = nalus_payloads ++ [last_nalu_payload]

    {nalus, _nalu_parser} =
      Enum.map_reduce(nalus_payloads, NALuParser.new(), &NALuParser.parse(&1, &2))

    {aus, au_splitter} = nalus |> AUSplitter.split_nalus(AUSplitter.new())
    {last_au, _au_splitter} = AUSplitter.flush(au_splitter)
    aus = aus ++ [last_au]

    Enum.map_reduce(aus, 0, fn au, ts ->
      {for(nalu <- au, do: %Membrane.Buffer{payload: nalu.payload, pts: ts, dts: ts}), ts + 1}
    end)
    |> elem(0)
    |> Enum.flat_map(& &1)
  end

  defp prepare_buffers(binary, mode) when mode == :au_aligned do
    {nalus_payloads, nalu_splitter} = binary |> NALuSplitter.split(NALuSplitter.new())
    {last_nalu_payload, _nalu_splitter} = NALuSplitter.flush(nalu_splitter)
    nalus_payloads = nalus_payloads ++ [last_nalu_payload]

    {nalus, _nalu_parser} =
      Enum.map_reduce(nalus_payloads, NALuParser.new(), &NALuParser.parse(&1, &2))

    {aus, au_splitter} = nalus |> AUSplitter.split_nalus(AUSplitter.new())
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
      caps: Membrane.RemoteStream

    @impl true
    def handle_init(opts) do
      {:ok, %{mode: opts.mode}}
    end

    @impl true
    def handle_other(actions, _ctx, state) do
      {{:ok, actions}, state}
    end

    @impl true
    def handle_prepared_to_playing(_ctx, state) do
      caps =
        case state.mode do
          :bytestream -> %Membrane.RemoteStream{type: :bytestream}
          :nalu_aligned -> %Membrane.RemoteStream{type: :packetized, content_format: :nalu}
          :au_aligned -> %Membrane.RemoteStream{type: :packetized, content_format: :au}
        end

      {{:ok, caps: {:output, caps}}, state}
    end
  end

  test "if the pts and dts are set to nil in :bytestream mode" do
    binary = File.read!(@h264_input_file)
    mode = :bytestream
    input_buffers = prepare_buffers(binary, mode)

    {:ok, pid} =
      Pipeline.start(
        links: [
          link(
            :source,
            %ModeTestSource{mode: mode}
          )
          |> to(:parser, Parser)
          |> to(:sink, Sink)
        ]
      )

    assert_pipeline_playback_changed(pid, :prepared, :playing)
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

    {:ok, pid} =
      Pipeline.start(
        links: [
          link(
            :source,
            %ModeTestSource{mode: mode}
          )
          |> to(:parser, Parser)
          |> to(:sink, Sink)
        ]
      )

    assert_pipeline_playback_changed(pid, :prepared, :playing)
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

    {:ok, pid} =
      Pipeline.start(
        links: [
          link(
            :source,
            %ModeTestSource{mode: mode}
          )
          |> to(:parser, Parser)
          |> to(:sink, Sink)
        ]
      )

    assert_pipeline_playback_changed(pid, :prepared, :playing)
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
