defmodule Membrane.H264.TimestampGenerationTest do
  @moduledoc false

  use ExUnit.Case

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions

  alias Membrane.Buffer
  alias Membrane.H264.Parser
  alias Membrane.H264.Parser.{AUSplitter, NALuParser, NALuSplitter}
  alias Membrane.H264.Support.TestSource
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

  @h264_input_file_main "test/fixtures/input-10-720p.h264"
  @h264_input_timestamps_main [
    {0, -500},
    {133, -467},
    {67, -433},
    {33, -400},
    {100, -367},
    {267, -333},
    {200, -300},
    {167, -267},
    {233, -233},
    {300, -200}
  ]
  @h264_input_file_baseline "test/fixtures/input-10-720p-baseline.h264"
  @h264_input_timestamps_baseline [0, 33, 67, 100, 133, 167, 200, 233, 267, 300]
                                  |> Enum.map(&{&1, &1})
  defp prepare_buffers(binary, :bytestream) do
    buffers =
      :binary.bin_to_list(binary) |> Enum.chunk_every(400) |> Enum.map(&:binary.list_to_bin(&1))

    Enum.map(buffers, &%Membrane.Buffer{payload: &1})
  end

  defp prepare_buffers(binary, :au_aligned) do
    {nalus_payloads, _nalu_splitter} = NALuSplitter.split(binary, true, NALuSplitter.new())
    {nalus, _nalu_parser} = NALuParser.parse_nalus(nalus_payloads, NALuParser.new())
    {aus, _au_splitter} = AUSplitter.split(nalus, true, AUSplitter.new())

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

  Enum.map(
    [
      {":baseline and :constrained_baseline", @h264_input_file_baseline,
       @h264_input_timestamps_baseline},
      {":main and higher", @h264_input_file_main, @h264_input_timestamps_main}
    ],
    fn {profiles, file, timestamps} ->
      test """
      if the pts and dts are generated correctly for profiles #{profiles}
      in :bytestream mode when framerate is given
      """ do
        binary = File.read!(unquote(file))
        mode = :bytestream
        input_buffers = prepare_buffers(binary, mode)

        framerate = {30, 1}

        {:ok, _supervisor_pid, pid} =
          Pipeline.start_supervised(
            structure: [
              child(:source, %TestSource{mode: mode})
              |> child(:parser, %Membrane.H264.Parser{
                generate_best_effort_timestamps: true,
                framerate: framerate
              })
              |> child(:sink, Sink)
            ]
          )

        assert_pipeline_play(pid)
        send_buffers_actions = for buffer <- input_buffers, do: {:buffer, {:output, buffer}}
        Pipeline.message_child(pid, :source, send_buffers_actions ++ [end_of_stream: :output])

        output_buffers = prepare_buffers(binary, :au_aligned)

        output_buffers
        |> Enum.zip(unquote(timestamps))
        |> Enum.each(fn {%Buffer{payload: ref_payload}, {ref_pts, ref_dts}} ->
          assert_sink_buffer(pid, :sink, %Buffer{payload: payload, pts: pts, dts: dts})

          assert {ref_payload, ref_pts, ref_dts} ==
                   {payload, Membrane.Time.as_milliseconds(pts, :round),
                    Membrane.Time.as_milliseconds(dts, :round)}
        end)

        Pipeline.terminate(pid, blocking?: true)
      end
    end
  )
end
