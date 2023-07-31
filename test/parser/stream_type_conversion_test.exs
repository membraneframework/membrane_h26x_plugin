defmodule Membrane.H264.StreamTypeConversionTest do
  use ExUnit.Case

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions
  import Membrane.H264.Support.Common

  alias Membrane.H264
  alias Membrane.Testing.{Pipeline, Sink}

  @annexb_fixtures "../fixtures/!(*no-sps*|*no-pps*).h264"
                   |> Path.expand(__DIR__)
                   |> Path.wildcard()

  @avc1_fixture "../fixtures/input-avc1.msf" |> Path.expand(__DIR__)
  @avc1_fixture_buffers 811

  defp make_pipeline(source, parser1, parser2) do
    structure =
      child(:source, source)
      |> child(:parser1, parser1)
      |> child(:parser2, parser2)
      |> child(:sink, Sink)

    Pipeline.start_link_supervised!(structure: structure)
  end

  defp perform_test(
         pipeline_pid,
         data,
         mode,
         parser_input_parsed_stream_type,
         data_parsed_stream_type
       ) do
    buffers =
      prepare_buffers(data, mode, data_parsed_stream_type, parser_input_parsed_stream_type, false)

    assert_pipeline_play(pipeline_pid)
    actions = for buffer <- buffers, do: {:buffer, {:output, buffer}}
    Pipeline.message_child(pipeline_pid, :source, actions ++ [end_of_stream: :output])

    Enum.each(buffers, fn output_buffer ->
      assert_sink_buffer(pipeline_pid, :sink, buffer)
      assert buffer.payload == output_buffer.payload
    end)

    assert_end_of_stream(pipeline_pid, :sink, :input, 3_000)
    Pipeline.terminate(pipeline_pid, blocking?: true)
  end

  defp make_avcc_pipeline(source_file_path, alignment) do
    structure = [
      child(:source1, %Membrane.File.Source{location: source_file_path})
      |> child(:deserializer1, Membrane.Stream.Deserializer)
      |> child(:parser1, %H264.Parser{
        output_alignment: alignment,
        output_parsed_stream_type: :annexb
      })
      |> child(:parser2, %H264.Parser{
        output_alignment: alignment,
        output_parsed_stream_type: {:avcc, 4}
      })
      |> child(:sink1, Sink),
      child(:source2, %Membrane.File.Source{location: source_file_path})
      |> child(:deserializer2, Membrane.Stream.Deserializer)
      |> child(:parser3, %H264.Parser{
        output_alignment: alignment,
        output_parsed_stream_type: {:avcc, 4}
      })
      |> child(:sink2, Sink)
    ]

    Pipeline.start_link_supervised!(structure: structure)
  end

  defp perform_avcc_test(pipeline_pid) do
    assert_pipeline_play(pipeline_pid)
    Pipeline.message_child(pipeline_pid, :source1, end_of_stream: :output)
    Pipeline.message_child(pipeline_pid, :source2, end_of_stream: :output)

    Enum.each(0..@avc1_fixture_buffers, fn _n ->
      assert_sink_buffer(pipeline_pid, :sink1, buffer1)
      assert_sink_buffer(pipeline_pid, :sink2, buffer2)
      assert buffer1.payload == buffer2.payload
    end)

    assert_end_of_stream(pipeline_pid, :sink1, :input, 3_000)
    assert_end_of_stream(pipeline_pid, :sink2, :input, 3_000)
    Pipeline.terminate(pipeline_pid, blocking?: true)
  end

  describe "The output stream should be the same as the input stream" do
    test "for au aligned streams annexb -> avcc -> annexb" do
      source = %H264.Support.TestSource{mode: :au_aligned, output_raw_stream_type: :annexb}
      parser1 = %H264.Parser{output_alignment: :au, output_parsed_stream_type: {:avcc, 4}}
      parser2 = %H264.Parser{output_alignment: :au, output_parsed_stream_type: :annexb}

      Enum.each(@annexb_fixtures, fn path ->
        pid = make_pipeline(source, parser1, parser2)
        perform_test(pid, File.read!(path), :au_aligned, :annexb, :annexb)
      end)
    end

    test "for nalu aligned streams annexb -> avcc -> annexb" do
      source = %H264.Support.TestSource{mode: :nalu_aligned, output_raw_stream_type: :annexb}
      parser1 = %H264.Parser{output_alignment: :nalu, output_parsed_stream_type: {:avcc, 4}}
      parser2 = %H264.Parser{output_alignment: :nalu, output_parsed_stream_type: :annexb}

      Enum.each(@annexb_fixtures, fn path ->
        pid = make_pipeline(source, parser1, parser2)
        perform_test(pid, File.read!(path), :nalu_aligned, :annexb, :annexb)
      end)
    end

    test "for au aligned streams avcc -> annexb -> avcc" do
      pid = make_avcc_pipeline(@avc1_fixture, :au)
      perform_avcc_test(pid)
    end
  end
end
