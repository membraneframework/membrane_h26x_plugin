defmodule Membrane.H264.ProcessAllTest do
  @moduledoc false

  use ExUnit.Case
  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions
  alias Membrane.H264
  alias Membrane.Testing.Pipeline

  defp make_pipeline(in_path, out_path) do
    structure = [
      child(:file_src, %Membrane.File.Source{chunk_size: 40_960, location: in_path})
      |> child(:parser, H264.Parser)
      |> child(:sink, %Membrane.File.Sink{location: out_path})
    ]

    Pipeline.start_link_supervised(structure: structure)
  end

  defp perform_test(filename, tmp_dir, timeout) do
    in_path = "../fixtures/input-#{filename}.h264" |> Path.expand(__DIR__)
    out_path = Path.join(tmp_dir, "output-all-#{filename}.h264")

    assert {:ok, _supervisor_pid, pid} = make_pipeline(in_path, out_path)
    assert_pipeline_play(pid)
    assert_end_of_stream(pid, :sink, :input, timeout)

    assert File.read(out_path) == File.read(in_path)

    Pipeline.terminate(pid, blocking?: true)
  end

  describe "ProcessAllPipeline should" do
    @describetag :tmp_dir

    test "process all 10 720p frames", ctx do
      perform_test("10-720p", ctx.tmp_dir, 1000)
    end

    test "process all 100 240p frames", ctx do
      perform_test("100-240p", ctx.tmp_dir, 1000)
    end

    test "process all 20 360p frames with 422 subsampling", ctx do
      perform_test("20-360p-I422", ctx.tmp_dir, 1000)
    end

    test "process all 10 720p frames with B frames in main profile", ctx do
      perform_test("10-720p-main", ctx.tmp_dir, 1000)
    end

    test "process all 10 720p frames with no b frames", ctx do
      perform_test("10-720p-no-b-frames", ctx.tmp_dir, 1000)
    end

    test "process all 100 240p frames with no b frames", ctx do
      perform_test("100-240p-no-b-frames", ctx.tmp_dir, 1000)
    end
  end
end
