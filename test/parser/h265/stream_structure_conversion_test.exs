defmodule Membrane.H265.StreamStructureConversionTest do
  @moduledoc false

  use ExUnit.Case, async: true

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions
  import Membrane.H26x.Support.Common

  alias Membrane.{H265, H26x}
  alias Membrane.Testing.{Pipeline, Sink}

  @annexb_fixtures "test/fixtures/h265/*.h265"
                   |> Path.wildcard()
                   |> Enum.reject(
                     &String.contains?(&1, ["no-parameter-sets", "no-irap", "no-vps"])
                   )

  @hvc1_au_fixtures "test/fixtures/h265/msr/*-hvc1-au.msr" |> Path.wildcard()
  @hvc1_nalu_fixtures "test/fixtures/h265/msr/*-hvc1-nalu.msr" |> Path.wildcard()
  @hev1_au_fixtures "test/fixtures/h265/msr/*-hev1-au.msr" |> Path.wildcard()
  @hev1_nalu_fixtures "test/fixtures/h265/msr/*-hev1-nalu.msr" |> Path.wildcard()

  defp make_annexb_pipeline(alignment, parsers) do
    parser_chain = make_parser_chain(parsers)

    mode = get_mode_from_alignment(alignment)

    spec =
      child(:source, %H26x.Support.TestSource{
        mode: mode,
        output_raw_stream_structure: :annexb,
        codec: :H265
      })
      |> parser_chain.()
      |> child(:parser_last, %H265.Parser{
        output_alignment: alignment,
        output_stream_structure: if(parsers != [], do: :annexb, else: nil)
      })
      |> child(:sink, Sink)

    Pipeline.start_link_supervised!(spec: spec)
  end

  defp perform_annexb_test(pipeline_pid, data, mode, identical_order?) do
    buffers = prepare_h265_buffers(data, mode, :annexb, false)
    assert_sink_playing(pipeline_pid, :sink)
    actions = for buffer <- buffers, do: {:buffer, {:output, buffer}}
    Pipeline.notify_child(pipeline_pid, :source, actions ++ [end_of_stream: :output])

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

    Pipeline.terminate(pipeline_pid)
  end

  defp make_hvc_pipelines(source_file_path, alignment, parsers, hvc) do
    fixture_pipeline_structure =
      child(:source, %Membrane.File.Source{location: source_file_path})
      |> child(:deserializer, Membrane.Stream.Deserializer)
      |> child(:sink, Sink)

    parser_chain = make_parser_chain(parsers)

    conversion_pipeline_structure =
      child(:source, %Membrane.File.Source{location: source_file_path})
      |> child(:deserializer, Membrane.Stream.Deserializer)
      |> parser_chain.()
      |> child(:parser_last, %H265.Parser{
        output_alignment: alignment,
        output_stream_structure: if(parsers != [], do: {hvc, 4}, else: nil)
      })
      |> child(:sink, Sink)

    {
      Pipeline.start_link_supervised!(spec: fixture_pipeline_structure),
      Pipeline.start_link_supervised!(spec: conversion_pipeline_structure)
    }
  end

  defp perform_hvc_test({fixture_pipeline_pid, conversion_pipeline_pid}, hvc) do
    assert_sink_playing(fixture_pipeline_pid, :sink)
    assert_end_of_stream(fixture_pipeline_pid, :sink, :input, 3_000)

    fixture_buffers = receive_buffer_payloads(fixture_pipeline_pid)

    assert_sink_stream_format(fixture_pipeline_pid, :sink, %H265{
      stream_structure: fixture_stream_structure
    })

    assert_sink_playing(conversion_pipeline_pid, :sink)
    assert_end_of_stream(conversion_pipeline_pid, :sink, :input, 3_000)

    converted_buffers = receive_buffer_payloads(conversion_pipeline_pid)

    case hvc do
      :hvc1 ->
        assert fixture_buffers == converted_buffers

        assert_sink_stream_format(conversion_pipeline_pid, :sink, %H265{
          stream_structure: conversion_stream_structure
        })

        assert fixture_stream_structure == conversion_stream_structure

      :hev1 ->
        assert_sink_stream_format(conversion_pipeline_pid, :sink, %H265{
          stream_structure: {:hev1, conversion_dcr}
        })

        %{nalu_length_size: converted_nalu_length_size} =
          H265.DecoderConfigurationRecord.parse(conversion_dcr)

        {:hev1, fixture_dcr} = fixture_stream_structure

        %{
          vpss: dcr_vpss,
          spss: dcr_spss,
          ppss: dcr_ppss,
          nalu_length_size: fixture_nalu_length_size
        } = H265.DecoderConfigurationRecord.parse(fixture_dcr)

        fixture_nalus =
          Enum.map(dcr_vpss, &add_length_prefix(&1, converted_nalu_length_size)) ++
            Enum.map(dcr_spss, &add_length_prefix(&1, converted_nalu_length_size)) ++
            Enum.map(dcr_ppss, &add_length_prefix(&1, converted_nalu_length_size)) ++
            split_aus_to_nalus(fixture_buffers, {:hev1, fixture_nalu_length_size})

        converted_nalus =
          split_aus_to_nalus(converted_buffers, {:hev1, converted_nalu_length_size})

        assert MapSet.equal?(MapSet.new(fixture_nalus), MapSet.new(converted_nalus))
    end

    Pipeline.terminate(fixture_pipeline_pid)
    Pipeline.terminate(conversion_pipeline_pid)
  end

  defp perform_test(stream_structure, alignment, parser_stream_structures, identical_order?) do
    parsers =
      Enum.map(parser_stream_structures, fn stream_structure ->
        %H265.Parser{
          output_alignment: alignment,
          output_stream_structure: stream_structure
        }
      end)

    case stream_structure do
      :annexb ->
        mode = get_mode_from_alignment(alignment)

        Enum.each(@annexb_fixtures, fn path ->
          pid = make_annexb_pipeline(alignment, parsers)
          perform_annexb_test(pid, File.read!(path), mode, identical_order?)
        end)

      hvc when hvc in [:hvc1, :hev1] ->
        fixtures =
          case {alignment, hvc} do
            {:au, :hvc1} -> @hvc1_au_fixtures
            {:nalu, :hvc1} -> @hvc1_nalu_fixtures
            {:au, :hev1} -> @hev1_au_fixtures
            {:nalu, :hev1} -> @hev1_nalu_fixtures
          end

        Enum.each(fixtures, fn path ->
          pids = make_hvc_pipelines(path, alignment, parsers, hvc)
          perform_hvc_test(pids, hvc)
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
    Enum.reduce(parsers, & &1, fn parser, builder -> &child(builder.(&1), parser) end)
  end

  defp split_aus_to_nalus(aus_binaries, stream_structure) do
    Enum.map(aus_binaries, fn au_binary ->
      {nalus, _splitter} =
        H26x.NALuSplitter.split(
          au_binary,
          true,
          H26x.NALuSplitter.new(stream_structure)
        )

      nalus
    end)
    |> List.flatten()
  end

  defp add_length_prefix(nalu_payload, nalu_length_size) do
    <<byte_size(nalu_payload)::integer-size(nalu_length_size)-unit(8), nalu_payload::binary>>
  end

  defp get_mode_from_alignment(alignment) do
    case alignment do
      :au -> :au_aligned
      :nalu -> :nalu_aligned
    end
  end

  describe "The output stream should be the same as the input stream" do
    generate_tests = fn tested_stream_structure_name, parser_chains, name_suffix ->
      for parser_types <- parser_chains do
        parser_chain_string =
          Enum.map_join(parser_types, fn parser_type ->
            case parser_type do
              :annexb -> "annexb -> "
              {:hvc1, _prefix_len} -> "hvc1 -> "
              {:hev1, _prefix_len} -> "hev1 -> "
            end
          end)

        identical_order? = not Enum.any?(parser_types, &match?({:hvc1, _prefix_len}, &1))

        stream_name =
          "stream #{tested_stream_structure_name} -> #{parser_chain_string}#{tested_stream_structure_name}#{name_suffix}"

        @tag String.to_atom("au aligned #{stream_name}")
        test "for au aligned #{stream_name}" do
          perform_test(
            unquote(tested_stream_structure_name),
            :au,
            unquote(parser_types),
            unquote(identical_order?)
          )
        end

        @tag String.to_atom("nalu aligned #{stream_name}")
        test "for nalu aligned #{stream_name}" do
          perform_test(
            unquote(tested_stream_structure_name),
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
        [],
        [{:hev1, 4}],
        [{:hvc1, 4}],
        [{:hvc1, 4}, {:hev1, 4}],
        [{:hev1, 4}, {:hvc1, 4}]
      ],
      ""
    )

    generate_tests.(
      :hvc1,
      [[], [:annexb], [{:hev1, 4}], [{:hev1, 4}, :annexb], [:annexb, {:hev1, 4}]],
      ""
    )

    generate_tests.(
      :hev1,
      [[], [:annexb], [{:hvc1, 4}], [{:hvc1, 4}, :annexb], [:annexb, {:hvc1, 4}]],
      ""
    )

    generate_tests.(:hvc1, [[{:hev1, 2}, {:hvc1, 3}, :annexb]], " with varying nalu_length_size")

    generate_tests.(
      :hvc1,
      [
        [
          {:hev1, 4},
          :annexb,
          {:hvc1, 4},
          :annexb,
          {:hev1, 4},
          :annexb,
          {:hvc1, 4},
          {:hev1, 4},
          :annexb,
          {:hvc1, 4},
          {:hev1, 4},
          :annexb,
          {:hvc1, 4}
        ]
      ],
      ""
    )
  end
end
