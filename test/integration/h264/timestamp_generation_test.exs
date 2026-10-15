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

  for {profile, file, frame_indices} <- [
        {:main, @h264_input_file_main, [0, 4, 2, 1, 3, 8, 6, 5, 7, 9]},
        {:baseline, @h264_input_file_baseline, Enum.to_list(0..9)}
      ],
      alignment <- [:au, :nalu] do
    test "infers DTS for #{profile} with #{alignment} input alignment" do
      binary = File.read!(unquote(file))
      frame_duration = div(Membrane.Time.second(), 30)
      start_pts = Membrane.Time.second()
      frame_indices = unquote(frame_indices)

      input_buffers =
        binary
        |> prepare_h264_buffers(unquote(alignment))
        |> Enum.map(fn buffer ->
          # The fixture helper assigns each NALU its containing AU's index.
          pts = start_pts + Enum.at(frame_indices, buffer.pts) * frame_duration
          %{buffer | pts: pts, dts: nil}
        end)

      expected_buffers =
        binary
        |> prepare_h264_buffers(:au)
        |> Enum.with_index()
        |> Enum.map(fn {buffer, index} ->
          %{
            buffer
            | pts: start_pts + Enum.at(frame_indices, index) * frame_duration,
              dts: start_pts + index * frame_duration
          }
        end)

      assert_timestamped_buffers(
        input_buffers,
        expected_buffers,
        unquote(alignment),
        %Parser{infer_dts_from_pts: true}
      )
    end
  end

  test "preserves supplied DTS when inference is enabled" do
    input_buffers =
      @h264_input_file_main
      |> File.read!()
      |> prepare_h264_buffers(:au)
      |> Enum.zip_with(@h264_input_timestamps_main, fn buffer, {pts, dts} ->
        %{buffer | pts: Membrane.Time.milliseconds(pts), dts: Membrane.Time.milliseconds(dts)}
      end)

    assert_timestamped_buffers(input_buffers, input_buffers, :au, %Parser{
      infer_dts_from_pts: true
    })
  end

  test "preserves missing DTS when inference is disabled by default" do
    input_buffers =
      @h264_input_file_main
      |> File.read!()
      |> prepare_h264_buffers(:au)
      |> Enum.zip_with(@h264_input_timestamps_main, fn buffer, {pts, _dts} ->
        %{buffer | pts: Membrane.Time.milliseconds(pts), dts: nil}
      end)

    assert_timestamped_buffers(input_buffers, input_buffers, :au, %Parser{})
  end

  defp assert_timestamped_buffers(input_buffers, expected_buffers, alignment, parser) do
    pid =
      Pipeline.start_supervised!(
        spec: [
          child(:source, %TestSource{alignment: alignment})
          |> child(:parser, parser)
          |> child(:sink, Sink)
        ]
      )

    assert_sink_playing(pid, :sink)
    actions = Enum.map(input_buffers, &{:buffer, {:output, &1}})
    Pipeline.notify_child(pid, :source, actions ++ [end_of_stream: :output])

    for %Buffer{payload: payload, pts: pts, dts: dts} <- expected_buffers do
      assert_sink_buffer(pid, :sink, %Buffer{payload: ^payload, pts: ^pts, dts: ^dts})
    end

    assert_end_of_stream(pid, :sink)
    Pipeline.terminate(pid)
  end

  test "if the pts and dts are set to nil for :bytestream input alignment when framerate isn't given" do
    binary = File.read!(@h264_input_file_baseline)
    alignment = :bytestream
    input_buffers = prepare_h264_buffers(binary, alignment)

    {:ok, _supervisor_pid, pid} =
      Pipeline.start_supervised(
        spec: [
          child(:source, %TestSource{alignment: alignment})
          |> child(:parser, Parser)
          |> child(:sink, Sink)
        ]
      )

    assert_sink_playing(pid, :sink)
    send_buffers_actions = for buffer <- input_buffers, do: {:buffer, {:output, buffer}}
    Pipeline.notify_child(pid, :source, send_buffers_actions ++ [end_of_stream: :output])

    output_buffers = prepare_h264_buffers(binary, :au)

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
      for :bytestream input alignment when framerate is given
      """ do
        binary = File.read!(unquote(file))
        alignment = :bytestream
        input_buffers = prepare_h264_buffers(binary, alignment)

        framerate = {30, 1}

        {:ok, _supervisor_pid, pid} =
          Pipeline.start_supervised(
            spec: [
              child(:source, %TestSource{alignment: alignment})
              |> child(:parser, %Membrane.H264.Parser{
                generate_best_effort_timestamps: %{framerate: framerate}
              })
              |> child(:sink, Sink)
            ]
          )

        assert_sink_playing(pid, :sink)
        send_buffers_actions = for buffer <- input_buffers, do: {:buffer, {:output, buffer}}
        Pipeline.notify_child(pid, :source, send_buffers_actions ++ [end_of_stream: :output])

        output_buffers = prepare_h264_buffers(binary, :au)

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
