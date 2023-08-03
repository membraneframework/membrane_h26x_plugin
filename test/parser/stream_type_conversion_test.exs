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

  @avc1_fixtures "../fixtures/*-avc1.msf" |> Path.expand(__DIR__) |> Path.wildcard()

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
         parser_input_parsed_stream_type
       ) do
    buffers = prepare_buffers(data, mode, parser_input_parsed_stream_type, false)

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

  defp make_avc1_pipeline(source_file_path, alignment, parsers) do
    fixture_pipeline_structure =
      child(:source, %Membrane.File.Source{location: source_file_path})
      |> child(:deserializer, Membrane.Stream.Deserializer)
      |> child(:sink, Sink)

    conversion_pipeline_structure =
      get_avc1_conversion_pipeline_structure(source_file_path, alignment, parsers)

    {
      Pipeline.start_link_supervised!(structure: fixture_pipeline_structure),
      Pipeline.start_link_supervised!(structure: conversion_pipeline_structure)
    }
  end

  defp get_avc1_conversion_pipeline_structure(source_file_path, alignment, [parser1]) do
    child(:source, %Membrane.File.Source{location: source_file_path})
    |> child(:deserializer, Membrane.Stream.Deserializer)
    |> child(:parser1, parser1)
    |> child(:parser2, %H264.Parser{
      output_alignment: alignment,
      output_parsed_stream_type: {:avc1, 4}
    })
    |> child(:sink, Sink)
  end

  defp get_avc1_conversion_pipeline_structure(source_file_path, alignment, [parser1, parser2]) do
    child(:source, %Membrane.File.Source{location: source_file_path})
    |> child(:deserializer, Membrane.Stream.Deserializer)
    |> child(:parser1, parser1)
    |> child(:parser2, parser2)
    |> child(:parser3, %H264.Parser{
      output_alignment: alignment,
      output_parsed_stream_type: {:avc1, 4}
    })
    |> child(:sink, Sink)
  end

  defp perform_avc1_test({fixture_pipeline_pid, conversion_pipeline_pid}) do
    assert_pipeline_play(fixture_pipeline_pid)
    Pipeline.message_child(fixture_pipeline_pid, :source, end_of_stream: :output)
    assert_end_of_stream(fixture_pipeline_pid, :sink, :input, 3_000)

    fixture_buffers_set = receive_buffers_set(fixture_pipeline_pid)

    assert_sink_stream_format(fixture_pipeline_pid, :sink, %H264{stream_type: fixture_stream_type})

    assert_pipeline_play(conversion_pipeline_pid)
    Pipeline.message_child(conversion_pipeline_pid, :source, end_of_stream: :output)
    assert_end_of_stream(conversion_pipeline_pid, :sink, :input, 3_000)

    converted_buffers_set = receive_buffers_set(conversion_pipeline_pid)

    assert MapSet.subset?(fixture_buffers_set, converted_buffers_set)

    IO.inspect(MapSet.difference(converted_buffers_set, fixture_buffers_set))

    assert_sink_stream_format(conversion_pipeline_pid, :sink, %H264{
      stream_type: ^fixture_stream_type
    })

    Pipeline.terminate(fixture_pipeline_pid)
    Pipeline.terminate(conversion_pipeline_pid)
  end

  defp receive_buffers_set(pipeline_pid, fixture_buffers \\ []) do
    receive do
      {Membrane.Testing.Pipeline, ^pipeline_pid,
       {:handle_child_notification, {{:buffer, buffer}, :sink}}} ->
        receive_buffers_set(pipeline_pid, [buffer.payload | fixture_buffers])
    after
      0 ->
        MapSet.new(fixture_buffers)
    end
  end

  describe "The output stream should be the same as the input stream" do
    test "for au aligned streams annexb -> avc3 -> annexb" do
      source = %H264.Support.TestSource{mode: :au_aligned, output_raw_stream_type: :annexb}
      parser1 = %H264.Parser{output_alignment: :au, output_parsed_stream_type: {:avcc, 4}}
      parser2 = %H264.Parser{output_alignment: :au, output_parsed_stream_type: :annexb}

      Enum.each(@annexb_fixtures, fn path ->
        pid = make_pipeline(source, parser1, parser2)
        perform_test(pid, File.read!(path), :au_aligned, :annexb)
      end)
    end

    test "for nalu aligned streams annexb -> avc3 -> annexb" do
      source = %H264.Support.TestSource{mode: :nalu_aligned, output_raw_stream_type: :annexb}
      parser1 = %H264.Parser{output_alignment: :nalu, output_parsed_stream_type: {:avcc, 4}}
      parser2 = %H264.Parser{output_alignment: :nalu, output_parsed_stream_type: :annexb}

      Enum.each(@annexb_fixtures, fn path ->
        pid = make_pipeline(source, parser1, parser2)
        perform_test(pid, File.read!(path), :nalu_aligned, :annexb)
      end)
    end

    test "for au aligned streams avc1 -> annexb -> avc1" do
      alignment = :au
      parsers = [%H264.Parser{output_alignment: alignment, output_parsed_stream_type: :annexb}]

      Enum.each(@avc1_fixtures, fn path ->
        pids = make_avc1_pipeline(path, alignment, parsers)
        perform_avc1_test(pids)
      end)
    end

    test "for au aligned streams avc1 -> annexb -> avc3 -> avc1" do
      alignment = :au

      parsers = [
        %H264.Parser{output_alignment: alignment, output_parsed_stream_type: :annexb},
        %H264.Parser{output_alignment: alignment, output_parsed_stream_type: {:avc3, 4}}
      ]

      Enum.each(@avc1_fixtures, fn path ->
        pids = make_avc1_pipeline(path, alignment, parsers)
        perform_avc1_test(pids)
      end)
    end

    test "for au aligned streams avc1 -> avc3 -> annexb -> avc1" do
      alignment = :au

      parsers = [
        %H264.Parser{output_alignment: alignment, output_parsed_stream_type: {:avc3, 4}},
        %H264.Parser{output_alignment: alignment, output_parsed_stream_type: :annexb}
      ]

      Enum.each(@avc1_fixtures, fn path ->
        pids = make_avc1_pipeline(path, alignment, parsers)
        perform_avc1_test(pids)
      end)
    end
  end
end
