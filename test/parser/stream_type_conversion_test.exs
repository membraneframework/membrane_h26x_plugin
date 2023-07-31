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

  @avc1_fixture "../fixtures/input-avc1-no-dcr.msf" |> Path.expand(__DIR__)
#  @avc1_fixture_buffers 811

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
    fixture_pipeline_structure =
      child(:source, %Membrane.File.Source{location: source_file_path})
      |> child(:deserializer, Membrane.Stream.Deserializer)
      |> child(:parser, %H264.Parser{
        output_alignment: alignment,
        output_parsed_stream_type: {:avcc, 4}
      })
      |> child(:sink, Sink)

    conversion_pipeline_structure =
      child(:source, %Membrane.File.Source{location: source_file_path})
      |> child(:deserializer, Membrane.Stream.Deserializer)
      |> child(:parser1, %H264.Parser{
        output_alignment: alignment,
        output_parsed_stream_type: :annexb
      })
      |> child(:filter, %Membrane.Debug.Filter{
        handle_buffer: &IO.inspect(&1, label: "buffer"),
        handle_stream_format: &IO.inspect(&1, label: "stream format")
      })
      |> child(:parser2, %H264.Parser{
        output_alignment: alignment,
        output_parsed_stream_type: {:avcc, 4}
      })
      |> child(:sink, Sink)

    {
      Pipeline.start_link_supervised!(structure: fixture_pipeline_structure),
      Pipeline.start_link_supervised!(structure: conversion_pipeline_structure)
    }
  end

  defp perform_avcc_test({fixture_pipeline_pid, conversion_pipeline_pid}) do
    assert_pipeline_play(fixture_pipeline_pid)
    Pipeline.message_child(fixture_pipeline_pid, :source, end_of_stream: :output)
    assert_end_of_stream(fixture_pipeline_pid, :sink, :input, 3_000)

#    IO.inspect(fixture_pipeline_pid)
#    IO.inspect(conversion_pipeline_pid)

    fixture_buffers_set = receive_buffers_set(fixture_pipeline_pid)
#    IO.inspect(fixture_buffers_set)

    assert_pipeline_play(conversion_pipeline_pid)
    Pipeline.message_child(conversion_pipeline_pid, :source, end_of_stream: :output)
    assert_end_of_stream(conversion_pipeline_pid, :sink, :input, 3_000)

    converted_buffers_set = receive_buffers_set(conversion_pipeline_pid)

    IO.inspect(MapSet.size(fixture_buffers_set))
    IO.inspect(MapSet.size(converted_buffers_set))

    Enum.each(fixture_buffers_set, &IO.inspect(&1, label: "fix", limit: :infinity, width: :infinity))
    Enum.each(converted_buffers_set, &IO.inspect(&1, label: "conv", limit: :infinity, width: :infinity))
#    MapSet.difference(fixture_buffers_set, converted_buffers_set)
#    |> IO.inspect()
#    |> MapSet.to_list()
#    |> hd()
#    |> byte_size()
#    |> IO.inspect()

    assert MapSet.subset?(fixture_buffers_set, converted_buffers_set)

    #
    #    Enum.each(0..@avc1_fixture_buffers, fn _n ->
    #      assert_sink_buffer(pipeline_pid, :sink1, buffer1)
    #      assert_sink_buffer(pipeline_pid, :sink2, buffer2)
    #      assert buffer1.payload == buffer2.payload
    #    end)
    #
    #    assert_end_of_stream(fixture_pipeline_pid, :sink1, :input, 3_000)
    Pipeline.terminate(fixture_pipeline_pid)
    Pipeline.terminate(conversion_pipeline_pid)
  end

  defp receive_buffers_set(pipeline_pid, fixture_buffers \\ []) do
    receive do
      {Membrane.Testing.Pipeline, ^pipeline_pid, {:handle_child_notification, {{:buffer, buffer}, :sink}}} ->
        receive_buffers_set(pipeline_pid, [buffer.payload | fixture_buffers])
    after
      0 ->
        MapSet.new(fixture_buffers)
    end
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
      pids = make_avcc_pipeline(@avc1_fixture, :au)
      perform_avcc_test(pids)
    end
  end
end
