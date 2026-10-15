defmodule Membrane.H264.PassthroughTest do
  use ExUnit.Case, async: true

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions

  alias Membrane.H264
  alias Membrane.Testing.{Pipeline, Sink, Source}

  @input_file "test/fixtures/h264/input-10-720p.h264"

  defp parsed_buffers(opts \\ []) do
    {:ok, _supervisor_pid, pid} =
      Pipeline.start_supervised(
        spec: [
          child(:source, %Membrane.File.Source{location: @input_file})
          |> child(:parser, struct!(H264.Parser, opts))
          |> child(:sink, Sink)
        ]
      )

    assert_sink_stream_format(pid, :sink, stream_format)
    assert_end_of_stream(pid, :sink)
    buffers = collect_buffers(pid)
    Pipeline.terminate(pid)
    {stream_format, buffers}
  end

  defp collect_buffers(pid, acc \\ []) do
    receive do
      {Membrane.Testing.Pipeline, ^pid, {:handle_child_notification, {{:buffer, buffer}, :sink}}} ->
        collect_buffers(pid, [buffer | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end

  defp run_second_parser(stream_format, buffers, opts) do
    {:ok, _supervisor_pid, pid} =
      Pipeline.start_supervised(
        spec: [
          child(:source, %Source{output: buffers, stream_format: stream_format})
          |> child(:parser, struct!(H264.Parser, opts))
          |> child(:sink, Sink)
        ]
      )

    assert_sink_stream_format(pid, :sink, out_stream_format)
    assert_end_of_stream(pid, :sink)
    out_buffers = collect_buffers(pid)
    Pipeline.terminate(pid)
    {out_stream_format, out_buffers}
  end

  test "already parsed AU-aligned input is forwarded untouched" do
    {stream_format, buffers} = parsed_buffers()
    assert %H264{alignment: :au, nalu_in_metadata?: true} = stream_format
    assert length(buffers) == 10

    {out_stream_format, out_buffers} = run_second_parser(stream_format, buffers, [])

    assert out_stream_format == stream_format
    assert out_buffers == buffers
  end

  test "the payload is not inspected in the passthrough mode" do
    {stream_format, buffers} = parsed_buffers()
    garbage = Enum.map(buffers, &%{&1 | payload: <<0, 0, 0, 1, 0xFF, 0xFF>>})

    {_out_stream_format, out_buffers} = run_second_parser(stream_format, garbage, [])
    assert out_buffers == garbage
  end

  test "skip_until_keyframe relies on the metadata in the passthrough mode" do
    {stream_format, buffers} = parsed_buffers()
    [keyframe | rest] = buffers
    assert keyframe.metadata.h264.key_frame?

    {_out_stream_format, out_buffers} =
      run_second_parser(stream_format, rest ++ [keyframe], skip_until_keyframe: true)

    assert out_buffers == [keyframe]
  end

  test "access units buffered before the switch to the passthrough mode are output first" do
    {stream_format, buffers} = parsed_buffers()
    {first_half, second_half} = Enum.split(buffers, 5)
    bytestream = Enum.map_join(first_half, & &1.payload)

    generator = fn
      :start, _size ->
        actions = [
          stream_format: {:output, %Membrane.RemoteStream{}},
          buffer: {:output, %Membrane.Buffer{payload: bytestream}},
          stream_format: {:output, stream_format},
          buffer: {:output, second_half},
          end_of_stream: :output
        ]

        {actions, :done}

      :done, _size ->
        {[], :done}
    end

    {:ok, _supervisor_pid, pid} =
      Pipeline.start_supervised(
        spec: [
          child(:source, %Source{output: {:start, generator}})
          |> child(:parser, H264.Parser)
          |> child(:sink, Sink)
        ]
      )

    assert_end_of_stream(pid, :sink)
    out_buffers = collect_buffers(pid)
    Pipeline.terminate(pid)

    assert Enum.map(out_buffers, & &1.payload) == Enum.map(buffers, & &1.payload)
  end

  test "options requiring the parameter sets fall back to the full parsing" do
    {stream_format, buffers} = parsed_buffers()
    {reference_format, reference} = parsed_buffers(output_stream_structure: :avc1)

    {out_stream_format, out_buffers} =
      run_second_parser(stream_format, buffers, output_stream_structure: :avc1)

    assert out_stream_format == reference_format
    assert Enum.map(out_buffers, & &1.payload) == Enum.map(reference, & &1.payload)
  end
end
