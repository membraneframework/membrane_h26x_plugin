defmodule Membrane.H264.TimestampGenerationTest do
  @moduledoc false

  use ExUnit.Case

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions

  alias Membrane.Buffer
  alias Membrane.H264.Parser
  alias Membrane.H264.Parser.{AUSplitter, NALuParser, NALuSplitter}
  alias Membrane.H264.TestSource
  alias Membrane.Testing.{Pipeline, Sink}

  defmodule EnhancedPipeline do
    use Membrane.Pipeline

    @impl true
    def handle_init(_ctx, args) do
      {[spec: args], %{}}
    end

    @impl true
    def handle_call({:get_child_pid, child}, ctx, state) do
      child_pid = Map.get(ctx.children, child).pid
      {[reply: child_pid], state}
    end
  end

  @h264_input_file "test/fixtures/input-10-720p.h264"
  @h264_input_file_baseline "test/fixtures/input-10-720p-baseline.h264"
  defp prepare_buffers(binary, :bytestream) do
    buffers =
      :binary.bin_to_list(binary) |> Enum.chunk_every(400) |> Enum.map(&:binary.list_to_bin(&1))

    Enum.map(buffers, &%Membrane.Buffer{payload: &1})
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

  test "if the pts and dts are set to nil in :bytestream mode when framerate isn't given" do
    binary = File.read!(@h264_input_file_baseline)
    mode = :bytestream
    input_buffers = prepare_buffers(binary, mode)

    {:ok, _supervisor_pid, pid} =
      Pipeline.start_supervised(
        structure: [
          child(:source, %TestSource{mode: mode})
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

  test """
  if the pts and dts are generated correctly for profiles :baseline and :constrained_baseline
  in :bytestream mode when framerate is given
  """ do
    binary = File.read!(@h264_input_file_baseline)
    mode = :bytestream
    input_buffers = prepare_buffers(binary, mode)

    framerate = {30, 1}

    {:ok, _supervisor_pid, pid} =
      Pipeline.start_supervised(
        structure: [
          child(:source, %TestSource{mode: mode})
          |> child(:parser, %Parser{framerate: framerate})
          |> child(:sink, Sink)
        ]
      )

    assert_pipeline_play(pid)
    send_buffers_actions = for buffer <- input_buffers, do: {:buffer, {:output, buffer}}
    Pipeline.message_child(pid, :source, send_buffers_actions ++ [end_of_stream: :output])

    output_buffers = prepare_buffers(binary, :au_aligned)

    {frames, seconds} = framerate

    Enum.reduce(output_buffers, 0, fn buf, order_number ->
      payload = buf.payload
      timestamp = div(seconds * Membrane.Time.second() * order_number, frames)
      assert_sink_buffer(pid, :sink, %Buffer{payload: ^payload, pts: ^timestamp, dts: ^timestamp})
      order_number + 1
    end)

    Pipeline.terminate(pid, blocking?: true)
  end

  test "if an error is raised when framerate is given for profiles other than :baseline and :constrained_baseline" do
    binary = File.read!(@h264_input_file)
    mode = :bytestream
    input_buffers = prepare_buffers(binary, mode)

    {:ok, _supervisor_pid, pid} =
      Pipeline.start_supervised(
        custom_args: [
          child(:source, %TestSource{mode: mode})
          |> child(:parser, %Parser{framerate: {30, 1}})
          |> child(:sink, Sink)
        ],
        module: EnhancedPipeline
      )

    Pipeline.execute_actions(pid, playback: :playing)
    assert_pipeline_play(pid)
    parser_pid = Membrane.Pipeline.call(pid, {:get_child_pid, :parser})
    send_buffers_actions = for buffer <- input_buffers, do: {:buffer, {:output, buffer}}

    Process.monitor(parser_pid)
    Pipeline.message_child(pid, :source, send_buffers_actions ++ [end_of_stream: :output])

    error =
      receive do
        {:DOWN, _ref, :process, ^parser_pid, {%RuntimeError{message: msg}, _stacktrace}} -> msg
      after
        2000 -> nil
      end

    assert error =~ ~r/timestamp.*generation.*unsupported/i

    Pipeline.terminate(pid, blocking?: true)
  end
end
