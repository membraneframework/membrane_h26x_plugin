defmodule Membrane.H264.ModesTest do
  use ExUnit.Case

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions
  import Membrane.H264.Support.Common

  alias Membrane.Buffer
  alias Membrane.H264.Parser
  alias Membrane.H264.Support.TestSource
  alias Membrane.Testing.{Pipeline, Sink}

  @h264_input_file "test/fixtures/input-10-720p.h264"

  test "if the pts and dts are set to nil in :bytestream mode" do
    binary = File.read!(@h264_input_file)
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

  test "if the pts and dts are rewritten properly in :nalu_aligned mode" do
    binary = File.read!(@h264_input_file)
    mode = :nalu_aligned
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
          child(:source, %TestSource{mode: mode})
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

  test "if single NAL unit is sent per buffer with `output_alignment: :nalu`" do
    {:ok, _supervisor_pid, pid} =
      Pipeline.start_supervised(
        structure: [
          child(:source, %Membrane.File.Source{location: @h264_input_file})
          |> child(:parser, %Parser{output_alignment: :nalu})
          |> child(:sink, Sink)
        ]
      )

    assert_pipeline_play(pid)
    assert_sink_stream_format(pid, :sink, %Membrane.H264{alignment: :nalu})

    binary = File.read!(@h264_input_file)
    ref_buffers = prepare_buffers(binary, :nalu_aligned)

    Enum.each(ref_buffers, fn ref_buffer ->
      assert_sink_buffer(pid, :sink, buffer)
      assert buffer.payload == ref_buffer.payload
      assert Map.has_key?(buffer.metadata, :h264) and Map.has_key?(buffer.metadata.h264, :type)
    end)

    assert_end_of_stream(pid, :sink)
    Pipeline.terminate(pid, blocking?: true)
  end
end
