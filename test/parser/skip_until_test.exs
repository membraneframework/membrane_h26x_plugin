defmodule Membrane.H264.SkipUntilTest do
  @moduledoc false

  use ExUnit.Case
  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions
  alias Membrane.H264
  alias Membrane.Testing.Pipeline

  defp make_pipeline(in_path, out_path, skip_until_keyframe) do
    structure = [
      child(:file_src, %Membrane.File.Source{chunk_size: 40_960, location: in_path})
      |> child(:parser, %H264.Parser{skip_until_keyframe: skip_until_keyframe})
      |> child(:sink, %Membrane.File.Sink{location: out_path})
    ]

    Pipeline.start_link_supervised(structure: structure)
  end

  describe "The parser should" do
    @describetag :tmp_dir

    test "skip the whole stream if no pps/sps are provided", ctx do
      filename = "10-no-pps-sps"
      in_path = "../fixtures/input-#{filename}.h264" |> Path.expand(__DIR__)
      out_path = Path.join(ctx.tmp_dir, "output-all-#{filename}.h264")

      assert {:ok, _supervisor_pid, pid} = make_pipeline(in_path, out_path, false)
      assert_pipeline_play(pid)
      refute_sink_buffer(pid, :sink, _)

      Pipeline.terminate(pid, blocking?: true)
    end

    test "skip until AU with IDR frame is provided, when `skip_until_keyframe: true`", ctx do
      filename = "sps-pps-non-idr-sps-pps-idr"
      in_path = "../fixtures/input-#{filename}.h264" |> Path.expand(__DIR__)
      out_path = Path.join(ctx.tmp_dir, "output-#{filename}.h264")
      ref_path = "test/fixtures/reference-#{filename}.h264"
      assert {:ok, _supervisor_pid, pid} = make_pipeline(in_path, out_path, true)
      assert_pipeline_play(pid)
      assert_end_of_stream(pid, :sink)
      assert File.read(out_path) == File.read(ref_path)
      Pipeline.terminate(pid, blocking?: true)
    end

    test "skip until AU with parameters is provided, no matter if it contains keyframe, when `skip_until_keyframe: false`",
         ctx do
      filename = "idr-sps-pps-non-idr"
      in_path = "../fixtures/input-#{filename}.h264" |> Path.expand(__DIR__)
      out_path = Path.join(ctx.tmp_dir, "output-#{filename}.h264")
      ref_path = "test/fixtures/reference-#{filename}.h264"
      assert {:ok, _supervisor_pid, pid} = make_pipeline(in_path, out_path, false)
      assert_pipeline_play(pid)
      assert_end_of_stream(pid, :sink)
      assert File.read(out_path) == File.read(ref_path)
      Pipeline.terminate(pid, blocking?: true)
    end

    test "skip until AU with parameters and IDR is provided, when `skip_until_keyframe: true`",
         ctx do
      filename = "idr-sps-pps-non-idr"
      in_path = "../fixtures/input-#{filename}.h264" |> Path.expand(__DIR__)
      out_path = Path.join(ctx.tmp_dir, "output-#{filename}.h264")
      assert {:ok, _supervisor_pid, pid} = make_pipeline(in_path, out_path, true)
      assert_pipeline_play(pid)
      refute_sink_buffer(pid, :sink, _)
      Pipeline.terminate(pid, blocking?: true)
    end
  end
end
