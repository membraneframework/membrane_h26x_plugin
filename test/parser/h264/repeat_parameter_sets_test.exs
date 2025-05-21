defmodule Membrane.H264.RepeatParameterSetsTest do
  @moduledoc false

  use ExUnit.Case, async: true

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions
  import Membrane.H26x.Support.Common

  alias Membrane.{H264, H26x}
  alias Membrane.H26x.NALuSplitter
  alias Membrane.Testing.{Pipeline, Sink}

  @in_path "test/fixtures/h264/input-30-240p-no-sps-pps.h264"
  @ref_path "test/fixtures/h264/reference-30-240p-with-sps-pps.h264"

  @sps <<103, 100, 0, 21, 172, 217, 65, 177, 254, 255, 252, 5, 0, 5, 4, 64, 0, 0, 3, 0, 64, 0, 0,
         15, 3, 197, 139, 101, 128>>
  @pps <<104, 235, 227, 203, 34, 192>>
  @dcr <<1, 100, 0, 21, 255, 225, 0, 29, 103, 100, 0, 21, 172, 217, 65, 177, 254, 255, 252, 5, 0,
         5, 4, 64, 0, 0, 3, 0, 64, 0, 0, 15, 3, 197, 139, 101, 128, 1, 0, 6, 104, 235, 227, 203,
         34, 192>>

  defp make_pipeline(source, spss \\ [], ppss \\ [], output_stream_structure \\ :annexb) do
    spec =
      child(:source, source)
      |> child(:parser, %H264.Parser{
        spss: spss,
        ppss: ppss,
        repeat_parameter_sets: true,
        output_stream_structure: output_stream_structure
      })
      |> child(:sink, Sink)

    Pipeline.start_link_supervised!(spec: spec)
  end

  defp perform_test(
         pipeline_pid,
         data,
         mode \\ :bytestream,
         parser_input_stream_structure \\ :annexb,
         parser_output_stream_structure \\ :annexb
       ) do
    buffers = prepare_h264_buffers(data, mode, parser_input_stream_structure)

    assert_sink_playing(pipeline_pid, :sink)
    actions = for buffer <- buffers, do: {:buffer, {:output, buffer}}
    Pipeline.notify_child(pipeline_pid, :source, actions ++ [end_of_stream: :output])

    output_buffers =
      prepare_h264_buffers(
        File.read!(@ref_path),
        :au_aligned,
        parser_output_stream_structure
      )

    Enum.each(output_buffers, fn output_buffer ->
      assert_sink_buffer(pipeline_pid, :sink, buffer)
      assert buffer.payload == output_buffer.payload
    end)

    assert_end_of_stream(pipeline_pid, :sink, :input, 3_000)
    Pipeline.terminate(pipeline_pid)
  end

  defp split_access_unit(access_unit) do
    {nalus, _splitter} = NALuSplitter.split(access_unit, true, NALuSplitter.new())
    Enum.sort(nalus)
  end

  describe "Parameter sets should be reapeated on each IDR access unit" do
    test "when provided by parser options" do
      source = %H26x.Support.TestSource{mode: :bytestream}
      pid = make_pipeline(source, [@sps], [@pps])
      perform_test(pid, File.read!(@in_path))
    end

    test "when retrieved from the bytestream" do
      source = %H26x.Support.TestSource{mode: :bytestream}
      pid = make_pipeline(source)

      data = Enum.join([<<>>, @sps, @pps], <<0, 0, 0, 1>>) <> File.read!(@in_path)
      perform_test(pid, data)
    end

    test "when provided via DCR" do
      source = %H26x.Support.TestSource{
        mode: :au_aligned,
        output_raw_stream_structure: {:avc3, @dcr}
      }

      pid = make_pipeline(source, [], [], {:avc3, 4})
      perform_test(pid, File.read!(@in_path), :au_aligned, {:avc3, 4}, {:avc3, 4})
    end

    test "when bytestream has variable parameter sets" do
      in_path = "./test/fixtures/h264/input-30-240p-vp-sps-pps.h264"
      ref_path = "./test/fixtures/h264/reference-30-240p-vp-sps-pps.h264"

      source = %H26x.Support.TestSource{mode: :bytestream}
      pid = make_pipeline(source)

      buffers = prepare_h264_buffers(File.read!(in_path), :bytestream)

      assert_sink_playing(pid, :sink)
      actions = for buffer <- buffers, do: {:buffer, {:output, buffer}}
      Pipeline.notify_child(pid, :source, actions ++ [end_of_stream: :output])

      File.read!(ref_path)
      |> prepare_h264_buffers(:au_aligned)
      |> Enum.each(fn output_buffer ->
        assert_sink_buffer(pid, :sink, buffer)
        assert split_access_unit(output_buffer.payload) == split_access_unit(buffer.payload)
      end)

      assert_end_of_stream(pid, :sink, :input, 3_000)
      Pipeline.terminate(pid)
    end
  end
end
