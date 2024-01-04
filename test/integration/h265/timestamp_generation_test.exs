defmodule Membrane.H265.TimestampGenerationTest do
  @moduledoc false

  use ExUnit.Case, async: true

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions
  import Membrane.H26x.Support.Common

  alias Membrane.Buffer
  alias Membrane.H265.Parser
  alias Membrane.H26x.Support.TestSource
  alias Membrane.Testing.{Pipeline, Sink}

  @h265_input_file_main "test/fixtures/h265/input-32-640x360-main.h265"
  @h265_input_timestamps_main [
    {0, -500},
    {67, -467},
    {33, -433},
    {100, -400},
    {167, -367},
    {133, -333},
    {233, -300},
    {200, -267},
    {300, -233},
    {267, -200},
    {367, -167},
    {333, -133},
    {400, -100},
    {467, -67},
    {433, -33},
    {533, 0},
    {500, 33},
    {600, 67},
    {567, 100},
    {667, 133},
    {633, 167},
    {700, 200},
    {767, 233},
    {733, 267},
    {833, 300},
    {800, 333},
    {900, 367},
    {867, 400},
    {967, 433},
    {933, 467},
    {1000, 500},
    {1067, 533},
    {1033, 567}
  ]

  @h265_input_file_baseline "test/fixtures/h265/input-10-1920x1080.h265"
  @h265_input_timestamps_baseline [0, 33, 67, 100, 133, 167, 200, 233, 267, 300]
                                  |> Enum.map(&{&1, &1 - 500})

  test "if the pts and dts are set to nil in :bytestream mode when framerate isn't given" do
    binary = File.read!(@h265_input_file_baseline)
    mode = :bytestream
    input_buffers = prepare_h265_buffers(binary, mode)

    {:ok, _supervisor_pid, pid} =
      Pipeline.start_supervised(
        spec: [
          child(:source, %TestSource{mode: mode, codec: :H265})
          |> child(:parser, Parser)
          |> child(:sink, Sink)
        ]
      )

    assert_sink_playing(pid, :sink)
    send_buffers_actions = for buffer <- input_buffers, do: {:buffer, {:output, buffer}}
    Pipeline.message_child(pid, :source, send_buffers_actions ++ [end_of_stream: :output])

    output_buffers = prepare_h265_buffers(binary, :au_aligned)

    Enum.each(output_buffers, fn buf ->
      payload = buf.payload
      assert_sink_buffer(pid, :sink, %Buffer{payload: ^payload, pts: nil, dts: nil})
    end)

    Pipeline.terminate(pid)
  end

  test "if the pts and dts are generated correctly for stream without frame reorder and no-bframes in :bytestream mode when framerate is given" do
    process_test(@h265_input_file_baseline, @h265_input_timestamps_baseline)
  end

  test "if the pts and dts are generated correctly in :bytestream mode when framerate is given" do
    process_test(@h265_input_file_main, @h265_input_timestamps_main)
  end

  test "if the pts and dts are generated correctly without dts offset in :bytestream mode when framerate is given" do
    process_test(@h265_input_file_main, @h265_input_timestamps_main, false)
  end

  defp process_test(file, timestamps, dts_offset \\ true) do
    binary = File.read!(file)
    mode = :bytestream
    input_buffers = prepare_h265_buffers(binary, mode)

    framerate = {30, 1}

    pid =
      Pipeline.start_supervised!(
        spec: [
          child(:source, %TestSource{mode: mode, codec: :H265})
          |> child(:parser, %Membrane.H265.Parser{
            generate_best_effort_timestamps: %{framerate: framerate, add_dts_offset: dts_offset}
          })
          |> child(:sink, Sink)
        ]
      )

    assert_sink_playing(pid, :sink)
    send_buffers_actions = for buffer <- input_buffers, do: {:buffer, {:output, buffer}}
    Pipeline.message_child(pid, :source, send_buffers_actions ++ [end_of_stream: :output])

    output_buffers = prepare_h265_buffers(binary, :au_aligned)

    output_buffers
    |> Enum.zip(timestamps)
    |> Enum.each(fn {%Buffer{payload: ref_payload}, {ref_pts, ref_dts}} ->
      {ref_pts, ref_dts} = if dts_offset, do: {ref_pts, ref_dts}, else: {ref_pts, ref_dts + 500}
      assert_sink_buffer(pid, :sink, %Buffer{payload: payload, pts: pts, dts: dts})

      assert {ref_payload, ref_pts, ref_dts} ==
               {payload, Membrane.Time.as_milliseconds(pts, :round),
                Membrane.Time.as_milliseconds(dts, :round)}
    end)

    Pipeline.terminate(pid)
  end
end
