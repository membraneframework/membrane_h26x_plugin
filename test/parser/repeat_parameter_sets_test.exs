defmodule Membrane.H264.RepeatParameterSetsTest do
  @moduledoc false

  use ExUnit.Case

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions
  import Membrane.H264.Support.Common

  alias Membrane.H264
  alias Membrane.H264.Parser.NALuSplitter
  alias Membrane.Testing.{Pipeline, Sink}

  @in_path "../fixtures/input-30-240p-no-sps-pps.h264" |> Path.expand(__DIR__)
  @ref_path "../fixtures/reference-30-240p-no-sps-pps.h264" |> Path.expand(__DIR__)

  @sps <<103, 100, 0, 21, 172, 217, 65, 177, 254, 255, 252, 5, 0, 5, 4, 64, 0, 0, 3, 0, 64, 0, 0,
         15, 3, 197, 139, 101, 128>>
  @pps <<104, 235, 227, 203, 34, 192>>
  @dcr <<1, 100, 0, 21, 255, 225, 0, 29, 103, 100, 0, 21, 172, 217, 65, 177, 254, 255, 252, 5, 0,
         5, 4, 64, 0, 0, 3, 0, 64, 0, 0, 15, 3, 197, 139, 101, 128, 1, 0, 6, 104, 235, 227, 203,
         34, 192>>

  defp make_pipeline(source, sps \\ <<>>, pps \\ <<>>) do
    structure = [
      child(:source, source)
      |> child(:parser, %H264.Parser{
        sps: sps,
        pps: pps,
        repeat_parameter_sets: true
      })
      |> child(:sink, Sink)
    ]

    Pipeline.start_link_supervised!(structure: structure)
  end

  defp perform_test(pipeline_pid, data, mode \\ :bytestream) do
    buffers = prepare_buffers(data, mode)

    assert_pipeline_play(pipeline_pid)
    actions = for buffer <- buffers, do: {:buffer, {:output, buffer}}
    Pipeline.message_child(pipeline_pid, :source, actions ++ [end_of_stream: :output])

    output_buffers = prepare_buffers(File.read!(@ref_path), :au_aligned)

    Enum.each(output_buffers, fn output_buffer ->
      assert_sink_buffer(pipeline_pid, :sink, buffer)
      assert buffer.payload == output_buffer.payload
    end)

    assert_end_of_stream(pipeline_pid, :sink, :input, 3_000)
    Pipeline.terminate(pipeline_pid, blocking?: true)
  end

  defp split_access_unit(access_unit) do
    {nalus, splitter} = NALuSplitter.split(access_unit, NALuSplitter.new())
    {remaining_nalu, _} = NALuSplitter.flush(splitter)

    Enum.sort(nalus ++ [remaining_nalu])
  end

  describe "Parameter sets should be reapeated on each IDR access unit" do
    test "when provided by parser options" do
      source = %H264.Support.TestSource{mode: :bytestream}
      pid = make_pipeline(source, @sps, @pps)
      perform_test(pid, File.read!(@in_path))
    end

    test "when retrieved from the bytestream" do
      source = %H264.Support.TestSource{mode: :bytestream}
      pid = make_pipeline(source)

      data = Enum.join([<<>>, @sps, @pps], <<0, 0, 0, 1>>) <> File.read!(@in_path)
      perform_test(pid, data)
    end

    test "when provided via DCR" do
      source = %H264.Support.TestSource{mode: :au_aligned, dcr: @dcr}
      pid = make_pipeline(source)
      perform_test(pid, File.read!(@in_path), :au_aligned)
    end

    test "when bytestream has variable parameter sets" do
      in_path = "./test/fixtures/input-30-240p-vp-sps-pps.h264"
      ref_path = "./test/fixtures/reference-30-240p-vp-sps-pps.h264"

      source = %H264.Support.TestSource{mode: :bytestream}
      pid = make_pipeline(source)

      buffers = prepare_buffers(File.read!(in_path), :bytestream)

      assert_pipeline_play(pid)
      actions = for buffer <- buffers, do: {:buffer, {:output, buffer}}
      Pipeline.message_child(pid, :source, actions ++ [end_of_stream: :output])

      File.read!(ref_path)
      |> prepare_buffers(:au_aligned)
      |> Enum.each(fn output_buffer ->
        assert_sink_buffer(pid, :sink, buffer)
        assert split_access_unit(output_buffer.payload) == split_access_unit(buffer.payload)
      end)

      assert_end_of_stream(pid, :sink, :input, 3_000)
      Pipeline.terminate(pid, blocking?: true)
    end
  end
end
