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
  @avc3_au_fixtures "../fixtures/msf/*-avc3-au.msf" |> Path.expand(__DIR__) |> Path.wildcard()
  @avc3_nalu_fixtures "../fixtures/msf/*-avc3-nalu.msf" |> Path.expand(__DIR__) |> Path.wildcard()

  defp make_annexb_pipeline(alignment, parsers) do
    parser_chain = make_parser_chain(parsers)

    mode =
      case alignment do
        :au -> :au_aligned
        :nalu -> :nalu_aligned
      end

    structure =
      child(:source, %H264.Support.TestSource{
        mode: mode,
        output_raw_stream_type: :annexb
      })
      |> parser_chain.()
      |> child(:parser_last, %H264.Parser{
        output_alignment: alignment,
        output_parsed_stream_type: :annexb
      })
      |> child(:sink, Sink)

    Pipeline.start_link_supervised!(structure: structure)
  end

  defp perform_annexb_test(pipeline_pid, data, mode, identical_order?) do
    buffers = prepare_buffers(data, mode, :annexb, false)
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
              MapSet.new(split_aus_to_nalus(fixture_buffers, :annexb)),
              MapSet.new(split_aus_to_nalus(converted_buffers, :annexb))
            }

          :nalu_aligned ->
            {MapSet.new(fixture_buffers), MapSet.new(converted_buffers)}
        end

      assert MapSet.equal?(fixture_nalus_set, converted_nalus_set)
    end

    Pipeline.terminate(pipeline_pid, blocking?: true)
  end

  defp make_avc_pipelines(source_file_path, alignment, parsers, avc) do
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
        output_parsed_stream_type: {avc, 4}
      })
      |> child(:sink, Sink)

    {
      Pipeline.start_link_supervised!(structure: fixture_pipeline_structure),
      Pipeline.start_link_supervised!(structure: conversion_pipeline_structure)
    }
  end

  defp perform_avc_test({fixture_pipeline_pid, conversion_pipeline_pid}, avc) do
    assert_pipeline_play(fixture_pipeline_pid)
    Pipeline.message_child(fixture_pipeline_pid, :source, end_of_stream: :output)
    assert_end_of_stream(fixture_pipeline_pid, :sink, :input, 3_000)

    fixture_buffers = receive_buffer_payloads(fixture_pipeline_pid)

    assert_sink_stream_format(fixture_pipeline_pid, :sink, %H264{stream_type: fixture_stream_type})

    assert_pipeline_play(conversion_pipeline_pid)
    Pipeline.message_child(conversion_pipeline_pid, :source, end_of_stream: :output)
    assert_end_of_stream(conversion_pipeline_pid, :sink, :input, 3_000)

    converted_buffers = receive_buffer_payloads(conversion_pipeline_pid)

    case avc do
      :avc1 ->
        assert fixture_buffers == converted_buffers

        assert_sink_stream_format(conversion_pipeline_pid, :sink, %H264{
          stream_type: ^fixture_stream_type
        })

      :avc3 ->
        assert_sink_stream_format(conversion_pipeline_pid, :sink, %H264{
          stream_type: {:avc3, conversion_dcr}
        })

        {:ok, %{nalu_length_size: converted_nalu_length_size}} =
          H264.Parser.DecoderConfigurationRecord.parse(conversion_dcr)

        {:avc3, fixture_dcr} = fixture_stream_type

        {:ok, %{spss: dcr_spss, ppss: dcr_ppss, nalu_length_size: fixture_nalu_length_size}} =
          H264.Parser.DecoderConfigurationRecord.parse(fixture_dcr)

        fixture_nalus =
          Enum.map(dcr_spss, &add_length_prefix(&1, converted_nalu_length_size)) ++
            Enum.map(dcr_ppss, &add_length_prefix(&1, converted_nalu_length_size)) ++
            split_aus_to_nalus(fixture_buffers, {:avc3, fixture_nalu_length_size})

        converted_nalus =
          split_aus_to_nalus(converted_buffers, {:avc3, converted_nalu_length_size})

        assert MapSet.equal?(MapSet.new(fixture_nalus), MapSet.new(converted_nalus))
    end

    Pipeline.terminate(fixture_pipeline_pid)
    Pipeline.terminate(conversion_pipeline_pid)
  end

  defp perform_test(stream_type, alignment, parser_stream_types, identical_order?) do
    parsers =
      Enum.map(parser_stream_types, fn stream_type ->
        %H264.Parser{output_alignment: alignment, output_parsed_stream_type: stream_type}
      end)

    case stream_type do
      :annexb ->
        mode =
          case alignment do
            :au -> :au_aligned
            :nalu -> :nalu_aligned
          end

        Enum.each(@annexb_fixtures, fn path ->
          pid = make_annexb_pipeline(alignment, parsers)
          perform_annexb_test(pid, File.read!(path), mode, identical_order?)
        end)

      avc when avc in [:avc1, :avc3] ->
        fixtures =
          case {alignment, avc} do
            {:au, :avc1} -> @avc1_au_fixtures
            {:nalu, :avc1} -> @avc1_nalu_fixtures
            {:au, :avc3} -> @avc3_au_fixtures
            {:nalu, :avc3} -> @avc3_nalu_fixtures
          end

        Enum.each(fixtures, fn path ->
          pids = make_avc_pipelines(path, alignment, parsers, avc)
          perform_avc_test(pids, avc)
        end)
    end
  end

  defp receive_buffer_payloads(pipeline_pid, acc \\ []) do
    receive do
      {Membrane.Testing.Pipeline, ^pipeline_pid,
       {:handle_child_notification, {{:buffer, buffer}, :sink}}} ->
        receive_buffer_payloads(pipeline_pid, acc ++ [buffer.payload])
    after
      0 ->
        acc
    end
  end

  defp make_parser_chain(parsers) do
    parsers
    |> Enum.with_index(fn elem, index -> {elem, String.to_atom("parser#{index}")} end)
    |> Enum.reduce(& &1, fn {parser, name}, builder ->
      &child(builder.(&1), name, parser)
    end)
  end

  defp split_aus_to_nalus(aus_binaries, parsed_stream_type) do
    Enum.map(aus_binaries, fn au_binary ->
      {nalus, splitter} =
        H264.Parser.NALuSplitter.split(
          au_binary,
          H264.Parser.NALuSplitter.new(parsed_stream_type)
        )

      case parsed_stream_type do
        :annexb ->
          nalus ++ [elem(H264.Parser.NALuSplitter.flush(splitter), 0)]

        {_avc, _} ->
          nalus
      end
    end)
    |> List.flatten()
  end

  defp add_length_prefix(nalu_payload, nalu_length_size) do
    <<byte_size(nalu_payload)::integer-size(nalu_length_size)-unit(8), nalu_payload::binary>>
  end

  describe "The output stream should be the same as the input stream" do
    generate_tests = fn tested_stream_type_name, parser_chains, name_suffix ->
      for parser_types <- parser_chains do
        parser_chain_string =
          Enum.map_join(parser_types, " -> ", fn parser_type ->
            case parser_type do
              :annexb -> "annexb"
              {:avc1, _} -> "avc1"
              {:avc3, _} -> "avc3"
            end
          end)

        identical_order? = not Enum.any?(parser_types, &match?({:avc1, _}, &1))

        stream_name =
          "stream #{tested_stream_type_name} -> #{parser_chain_string} -> #{tested_stream_type_name} #{name_suffix}"

        @tag String.to_atom("au aligned #{stream_name}")
        test "for au aligned #{stream_name}" do
          perform_test(
            unquote(tested_stream_type_name),
            :au,
            unquote(parser_types),
            unquote(identical_order?)
          )
        end

        @tag String.to_atom("nalu aligned #{stream_name}")
        test "for nalu aligned #{stream_name}" do
          perform_test(
            unquote(tested_stream_type_name),
            :nalu,
            unquote(parser_types),
            unquote(identical_order?)
          )
        end
      end
    end

    generate_tests.(
      :annexb,
      [
        [{:avc3, 4}],
        [{:avc1, 4}],
        [{:avc1, 4}, {:avc3, 4}],
        [{:avc3, 4}, {:avc1, 4}]
      ],
      ""
    )

    generate_tests.(
      :avc1,
      [[:annexb], [{:avc3, 4}], [{:avc3, 4}, :annexb], [:annexb, {:avc3, 4}]],
      ""
    )

    generate_tests.(
      :avc3,
      [[:annexb], [{:avc1, 4}], [{:avc1, 4}, :annexb], [:annexb, {:avc1, 4}]],
      ""
    )

    generate_tests.(:avc1, [[{:avc3, 2}, {:avc1, 3}, :annexb]], "with varying nalu_length_size")

    generate_tests.(
      :avc1,
      [
        [
          {:avc3, 4},
          :annexb,
          {:avc1, 4},
          :annexb,
          {:avc3, 4},
          :annexb,
          {:avc1, 4},
          {:avc3, 4},
          :annexb,
          {:avc1, 4},
          {:avc3, 4},
          :annexb,
          {:avc1, 4}
        ]
      ],
      ""
    )
  end
end
