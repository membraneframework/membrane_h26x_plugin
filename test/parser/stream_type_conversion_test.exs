defmodule Membrane.H264.StreamTypeConversionTest do
  use ExUnit.Case

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions
  import Membrane.H264.Support.Common

  alias Membrane.H264
  alias Membrane.Testing.{Pipeline, Sink}

  @annexb_fixtures "../fixtures/*.h264"
                   |> Path.expand(__DIR__)
                   |> Path.wildcard()
                   |> Enum.reject(
                     &String.contains?(&1, ["no-sps", "no-pps", "input-idr-sps-pps"])
                   )

  @avc1_au_fixtures "../fixtures/msf/*-avc1-au.msf" |> Path.expand(__DIR__) |> Path.wildcard()
  @avc1_nalu_fixtures "../fixtures/msf/*-avc1-nalu.msf" |> Path.expand(__DIR__) |> Path.wildcard()

  defp make_annexb_pipeline(mode, parsers) do
    parser_chain = make_parser_chain(parsers)

    structure =
      child(:source, %H264.Support.TestSource{mode: mode, output_raw_stream_type: :annexb})
      |> parser_chain.()
      |> child(:sink, Sink)

    Pipeline.start_link_supervised!(structure: structure)
  end

  defp perform_annexb_test(
         pipeline_pid,
         data,
         mode,
         parser_input_parsed_stream_type,
         identical_order?
       ) do
    buffers = prepare_buffers(data, mode, parser_input_parsed_stream_type, false)
    assert_pipeline_play(pipeline_pid)
    actions = for buffer <- buffers, do: {:buffer, {:output, buffer}}
    Pipeline.message_child(pipeline_pid, :source, actions ++ [end_of_stream: :output])

    assert_end_of_stream(pipeline_pid, :sink, :input, 3_000)

    if identical_order? do
      Enum.each(buffers, fn output_buffer ->
        assert_sink_buffer(pipeline_pid, :sink, buffer)
        assert buffer.payload == output_buffer.payload
      end)
    else
      converted_buffers = receive_buffer_payloads(pipeline_pid)

      fixture_buffers = Enum.map(buffers, & &1.payload)

      {fixture_nalus_set, converted_nalus_set} =
        case mode do
          :au_aligned ->
            {
              MapSet.new(convert_aus_to_nalus(fixture_buffers)),
              MapSet.new(convert_aus_to_nalus(converted_buffers))
            }

          :nalu_aligned ->
            {MapSet.new(fixture_buffers), MapSet.new(converted_buffers)}
        end

      assert MapSet.equal?(fixture_nalus_set, converted_nalus_set)
    end

    Pipeline.terminate(pipeline_pid, blocking?: true)
  end

  defp convert_aus_to_nalus(aus_binaries) do
    Enum.map(aus_binaries, fn au_binary ->
      {nalus, splitter} =
        H264.Parser.NALuSplitter.split(au_binary, H264.Parser.NALuSplitter.new())

      nalus ++ [elem(H264.Parser.NALuSplitter.flush(splitter), 0)]
    end)
    |> List.flatten()
  end

  defp make_avc1_pipelines(source_file_path, alignment, parsers) do
    fixture_pipeline_structure =
      child(:source, %Membrane.File.Source{location: source_file_path})
      |> child(:deserializer, Membrane.Stream.Deserializer)
      |> child(:sink, Sink)

    parser_chain = make_parser_chain(parsers)

    conversion_pipeline_structure =
      child(:source, %Membrane.File.Source{location: source_file_path})
      |> child(:deserializer, Membrane.Stream.Deserializer)
      |> parser_chain.()
      |> child(:parser_last, %H264.Parser{
        output_alignment: alignment,
        output_parsed_stream_type: {:avc1, 4}
      })
      |> child(:sink, Sink)

    {
      Pipeline.start_link_supervised!(structure: fixture_pipeline_structure),
      Pipeline.start_link_supervised!(structure: conversion_pipeline_structure)
    }
  end

  defp perform_avc1_test({fixture_pipeline_pid, conversion_pipeline_pid}) do
    assert_pipeline_play(fixture_pipeline_pid)
    Pipeline.message_child(fixture_pipeline_pid, :source, end_of_stream: :output)
    assert_end_of_stream(fixture_pipeline_pid, :sink, :input, 3_000)

    fixture_nalus_set = MapSet.new(receive_buffer_payloads(fixture_pipeline_pid))

    assert_sink_stream_format(fixture_pipeline_pid, :sink, %H264{stream_type: fixture_stream_type})

    assert_pipeline_play(conversion_pipeline_pid)
    Pipeline.message_child(conversion_pipeline_pid, :source, end_of_stream: :output)
    assert_end_of_stream(conversion_pipeline_pid, :sink, :input, 3_000)

    converted_nalus_set = MapSet.new(receive_buffer_payloads(conversion_pipeline_pid))

    assert MapSet.equal?(fixture_nalus_set, converted_nalus_set)

    assert_sink_stream_format(conversion_pipeline_pid, :sink, %H264{
      stream_type: ^fixture_stream_type
    })

    Pipeline.terminate(fixture_pipeline_pid)
    Pipeline.terminate(conversion_pipeline_pid)
  end

  defp receive_buffer_payloads(pipeline_pid, acc \\ []) do
    receive do
      {Membrane.Testing.Pipeline, ^pipeline_pid,
       {:handle_child_notification, {{:buffer, buffer}, :sink}}} ->
        receive_buffer_payloads(pipeline_pid, [buffer.payload | acc])
    after
      0 ->
        acc
    end
  end

  defp make_parser_chain(parsers) do
    case parsers do
      [parser1] ->
        &(&1 |> child(:parser1, parser1))

      [parser1, parser2] ->
        &(&1 |> child(:parser1, parser1) |> child(:parser2, parser2))

      [parser1, parser2, parser3] ->
        &(&1 |> child(:parser1, parser1) |> child(:parser2, parser2) |> child(:parser3, parser3))
    end
  end

  defp perform_standard_annexb_tests(alignment, stream_type) do
    parsers = [
      %H264.Parser{output_alignment: alignment, output_parsed_stream_type: stream_type},
      %H264.Parser{output_alignment: alignment, output_parsed_stream_type: :annexb}
    ]

    identical_order? = not match?({:avc1, _}, stream_type)

    mode =
      case alignment do
        :au -> :au_aligned
        :nalu -> :nalu_aligned
      end

    Enum.each(@annexb_fixtures, fn path ->
      pid = make_annexb_pipeline(mode, parsers)
      perform_annexb_test(pid, File.read!(path), mode, :annexb, identical_order?)
    end)
  end

  describe "The output stream should be the same as the input stream" do
    test "for au aligned stream annexb -> avc3 -> annexb" do
      perform_standard_annexb_tests(:au, {:avc3, 4})
    end

    test "for nalu aligned stream annexb -> avc3 -> annexb" do
      perform_standard_annexb_tests(:nalu, {:avc3, 4})
    end

    test "for au aligned stream annexb -> avc1 -> annexb" do
      perform_standard_annexb_tests(:au, {:avc1, 4})
    end

    test "for nalu aligned stream annexb -> avc1 -> annexb" do
      perform_standard_annexb_tests(:nalu, {:avc1, 4})
    end

    test "for au aligned stream avc1 -> annexb -> avc1" do
      alignment = :au
      parsers = [%H264.Parser{output_alignment: alignment, output_parsed_stream_type: :annexb}]

      Enum.each(@avc1_au_fixtures, fn path ->
        pids = make_avc1_pipelines(path, alignment, parsers)
        perform_avc1_test(pids)
      end)
    end

    test "for au aligned stream avc1 -> annexb -> avc3 -> avc1" do
      alignment = :au

      parsers = [
        %H264.Parser{output_alignment: alignment, output_parsed_stream_type: :annexb},
        %H264.Parser{output_alignment: alignment, output_parsed_stream_type: {:avc3, 4}}
      ]

      Enum.each(@avc1_au_fixtures, fn path ->
        IO.inspect(path)
        pids = make_avc1_pipelines(path, alignment, parsers)
        perform_avc1_test(pids)
      end)
    end

    test "for au aligned stream avc1 -> avc3 -> annexb -> avc1" do
      alignment = :au

      parsers = [
        %H264.Parser{output_alignment: alignment, output_parsed_stream_type: {:avc3, 4}},
        %H264.Parser{output_alignment: alignment, output_parsed_stream_type: :annexb}
      ]

      Enum.each(@avc1_au_fixtures, fn path ->
        pids = make_avc1_pipelines(path, alignment, parsers)
        perform_avc1_test(pids)
      end)
    end
  end
end
