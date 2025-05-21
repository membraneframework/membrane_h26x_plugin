defmodule Membrane.H265.ModesTest do
  @moduledoc false
  use ExUnit.Case, async: true

  import Membrane.ChildrenSpec
  import Membrane.H26x.Support.Common
  import Membrane.Testing.Assertions

  alias Membrane.Buffer
  alias Membrane.H265.Parser
  alias Membrane.H26x.Support.TestSource
  alias Membrane.Testing.{Pipeline, Sink}

  @h265_input_file "test/fixtures/h265/input-8-2K.h265"

  test "if the pts and dts are set to nil in :bytestream mode" do
    binary = File.read!(@h265_input_file)
    mode = :bytestream
    input_buffers = prepare_h265_buffers(binary, mode)

    pid =
      Pipeline.start_supervised!(
        spec: [
          child(:source, %TestSource{mode: mode, codec: :H265})
          |> child(:parser, Parser)
          |> child(:sink, Sink)
        ]
      )

    assert_sink_playing(pid, :sink)
    send_buffers_actions = for buffer <- input_buffers, do: {:buffer, {:output, buffer}}
    Pipeline.notify_child(pid, :source, send_buffers_actions ++ [end_of_stream: :output])

    output_buffers = prepare_h265_buffers(binary, :au_aligned)

    Enum.each(output_buffers, fn buf ->
      payload = buf.payload
      assert_sink_buffer(pid, :sink, %Buffer{payload: ^payload, pts: nil, dts: nil})
    end)

    Pipeline.terminate(pid)
  end

  test "if the pts and dts are rewritten properly in :nalu_aligned mode" do
    binary = File.read!(@h265_input_file)
    mode = :nalu_aligned
    input_buffers = prepare_h265_buffers(binary, mode)

    pid =
      Pipeline.start_supervised!(
        spec: [
          child(:source, %TestSource{mode: mode, codec: :H265})
          |> child(:parser, Parser)
          |> child(:sink, Sink)
        ]
      )

    assert_sink_playing(pid, :sink)
    send_buffers_actions = for buffer <- input_buffers, do: {:buffer, {:output, buffer}}
    Pipeline.notify_child(pid, :source, send_buffers_actions ++ [end_of_stream: :output])

    output_buffers = prepare_h265_buffers(binary, :au_aligned)

    Enum.each(output_buffers, fn buf ->
      payload = buf.payload
      pts = buf.pts
      dts = buf.dts
      assert_sink_buffer(pid, :sink, %Buffer{payload: ^payload, pts: ^pts, dts: ^dts})
    end)

    Pipeline.terminate(pid)
  end

  test "if the pts and dts are rewritten properly in :au_aligned mode" do
    binary = File.read!(@h265_input_file)
    mode = :au_aligned
    input_buffers = prepare_h265_buffers(binary, mode)

    pid =
      Pipeline.start_supervised!(
        spec: [
          child(:source, %TestSource{mode: mode, codec: :H265})
          |> child(:parser, Parser)
          |> child(:sink, Sink)
        ]
      )

    assert_sink_playing(pid, :sink)
    send_buffers_actions = for buffer <- input_buffers, do: {:buffer, {:output, buffer}}
    Pipeline.notify_child(pid, :source, send_buffers_actions ++ [end_of_stream: :output])

    output_buffers = input_buffers

    Enum.each(output_buffers, fn buf ->
      payload = buf.payload
      pts = buf.pts
      dts = buf.dts
      assert_sink_buffer(pid, :sink, %Buffer{payload: ^payload, pts: ^pts, dts: ^dts})
    end)

    Pipeline.terminate(pid)
  end

  test "if single NAL unit is sent per buffer with `output_alignment: :nalu`" do
    pid =
      Pipeline.start_supervised!(
        spec: [
          child(:source, %Membrane.File.Source{location: @h265_input_file})
          |> child(:parser, %Parser{output_alignment: :nalu})
          |> child(:sink, Sink)
        ]
      )

    assert_sink_playing(pid, :sink)
    assert_sink_stream_format(pid, :sink, %Membrane.H265{alignment: :nalu})

    binary = File.read!(@h265_input_file)
    ref_buffers = prepare_h265_buffers(binary, :nalu_aligned)

    Enum.each(ref_buffers, fn ref_buffer ->
      assert_sink_buffer(pid, :sink, buffer)
      assert buffer.payload == ref_buffer.payload
      assert Map.has_key?(buffer.metadata, :h265) and Map.has_key?(buffer.metadata.h265, :type)
    end)

    assert_end_of_stream(pid, :sink)
    Pipeline.terminate(pid)
  end
end
