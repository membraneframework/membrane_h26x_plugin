defmodule Membrane.H264.TimestampGenerationTest do
  @moduledoc false

  use ExUnit.Case, async: true

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions
  import Membrane.H26x.Support.Common

  alias Membrane.Buffer
  alias Membrane.H264.Parser
  alias Membrane.H26x.Support.TestSource
  alias Membrane.Testing.{Pipeline, Sink}

  @h264_input_file_main "test/fixtures/h264/input-10-720p.h264"
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
  @h264_input_file_baseline "test/fixtures/h264/input-10-720p-baseline.h264"
  @h264_input_timestamps_baseline [0, 33, 67, 100, 133, 167, 200, 233, 267, 300]
                                  |> Enum.map(&{&1, &1 - 500})

  test "if the pts and dts are set to nil in :bytestream mode when framerate isn't given" do
    binary = File.read!(@h264_input_file_baseline)
    mode = :bytestream
    input_buffers = prepare_buffers(binary, mode)

    {:ok, _supervisor_pid, pid} =
      Pipeline.start_supervised(
        spec: [
          child(:source, %TestSource{mode: mode})
          |> child(:parser, Parser)
          |> child(:sink, Sink)
        ]
      )

    assert_sink_playing(pid, :sink)
    send_buffers_actions = for buffer <- input_buffers, do: {:buffer, {:output, buffer}}
    Pipeline.message_child(pid, :source, send_buffers_actions ++ [end_of_stream: :output])

    output_buffers = prepare_buffers(binary, :au_aligned)

    Enum.each(output_buffers, fn buf ->
      payload = buf.payload
      assert_sink_buffer(pid, :sink, %Buffer{payload: ^payload, pts: nil, dts: nil})
    end)

    Pipeline.terminate(pid)
  end

  Enum.map(
    [
      {":baseline and :constrained_baseline", @h264_input_file_baseline,
       @h264_input_timestamps_baseline},
      {":main and higher", @h264_input_file_main, @h264_input_timestamps_main}
    ],
    fn {profiles, file, timestamps} ->
      test """
      if the pts and dts are generated correctly for profiles #{profiles}\
      in :bytestream mode when framerate is given
      """ do
        binary = File.read!(unquote(file))
        mode = :bytestream
        input_buffers = prepare_buffers(binary, mode)

        framerate = {30, 1}

        {:ok, _supervisor_pid, pid} =
          Pipeline.start_supervised(
            spec: [
              child(:source, %TestSource{mode: mode})
              |> child(:parser, %Membrane.H264.Parser{
                generate_best_effort_timestamps: %{framerate: framerate}
              })
              |> child(:sink, Sink)
            ]
          )

        assert_sink_playing(pid, :sink)
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

        Pipeline.terminate(pid)
      end
    end
  )
end
