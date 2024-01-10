defmodule Membrane.H265.RepeatParameterSetsTest do
  @moduledoc false

  use ExUnit.Case, async: true

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions
  import Membrane.H26x.Support.Common

  alias Membrane.{H265, H26x}
  alias Membrane.H26x.NALuSplitter
  alias Membrane.Testing.{Pipeline, Sink}

  @in_path "test/fixtures/h265/input-60-640x480-no-parameter-sets.h265"
  @ref_path "test/fixtures/h265/reference-60-640x480-with-parameter-sets.h265"

  @vps <<64, 1, 12, 1, 255, 255, 33, 96, 0, 0, 3, 0, 144, 0, 0, 3, 0, 0, 3, 0, 153, 149, 152, 9>>
  @sps <<66, 1, 1, 33, 96, 0, 0, 3, 0, 144, 0, 0, 3, 0, 0, 3, 0, 153, 160, 5, 2, 1, 225, 101, 149,
         154, 73, 50, 188, 57, 160, 32, 0, 0, 3, 0, 32, 0, 0, 3, 3, 193>>
  @pps <<68, 1, 193, 114, 180, 98, 64>>
  @dcr <<1, 33, 96, 0, 0, 0, 144, 0, 0, 0, 0, 0, 153, 240, 0, 252, 253, 248, 248, 0, 0, 15, 3,
         160, 0, 1, 0, 24, 64, 1, 12, 1, 255, 255, 33, 96, 0, 0, 3, 0, 144, 0, 0, 3, 0, 0, 3, 0,
         153, 149, 152, 9, 161, 0, 1, 0, 42, 66, 1, 1, 33, 96, 0, 0, 3, 0, 144, 0, 0, 3, 0, 0, 3,
         0, 153, 160, 5, 2, 1, 225, 101, 149, 154, 73, 50, 188, 57, 160, 32, 0, 0, 3, 0, 32, 0, 0,
         3, 3, 193, 162, 0, 1, 0, 7, 68, 1, 193, 114, 180, 98, 64>>

  defp make_pipeline(
         source,
         vpss \\ [],
         spss \\ [],
         ppss \\ [],
         output_stream_structure \\ :annexb
       ) do
    spec =
      child(:source, source)
      |> child(:parser, %H265.Parser{
        vpss: vpss,
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
    Pipeline.message_child(pipeline_pid, :source, actions ++ [end_of_stream: :output])

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

  describe "Parameter sets should be reapeated on each IRAP access unit" do
    test "when provided by parser options" do
      source = %H26x.Support.TestSource{mode: :bytestream}
      pid = make_pipeline(source, [@vps], [@sps], [@pps])
      perform_test(pid, File.read!(@in_path))
    end

    test "when retrieved from the bytestream" do
      source = %H26x.Support.TestSource{mode: :bytestream}
      pid = make_pipeline(source)

      data = Enum.join([<<>>, @vps, @sps, @pps], <<0, 0, 0, 1>>) <> File.read!(@in_path)
      perform_test(pid, data)
    end

    test "when provided via DCR" do
      source = %H26x.Support.TestSource{
        mode: :au_aligned,
        output_raw_stream_structure: {:hev1, @dcr},
        codec: :H265
      }

      pid = make_pipeline(source, [], [], [], {:hev1, 4})
      perform_test(pid, File.read!(@in_path), :au_aligned, {:hev1, 4}, {:hev1, 4})
    end

    test "when bytestream has variable parameter sets" do
      in_path = "test/fixtures/h265/input-60-640x480-variable-parameters.h265"
      ref_path = "test/fixtures/h265/reference-60-640x480-variable-parameters.h265"

      source = %H26x.Support.TestSource{mode: :bytestream}
      pid = make_pipeline(source)

      buffers = prepare_h264_buffers(File.read!(in_path), :bytestream)

      assert_sink_playing(pid, :sink)
      actions = for buffer <- buffers, do: {:buffer, {:output, buffer}}
      Pipeline.message_child(pid, :source, actions ++ [end_of_stream: :output])

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
