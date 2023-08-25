defmodule Membrane.H264.ProcessAllTest do
  @moduledoc false

  use ExUnit.Case, async: true
  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions
  alias Membrane.H264
  alias Membrane.Testing.Pipeline

  @prefix <<1::32>>

  defp make_pipeline(in_path, out_path, spss, ppss) do
    structure = [
      child(:file_src, %Membrane.File.Source{chunk_size: 40_960, location: in_path})
      |> child(:parser, %H264.Parser{spss: spss, ppss: ppss})
      |> child(:sink, %Membrane.File.Sink{location: out_path})
    ]

    Pipeline.start_link_supervised(structure: structure)
  end

  defp perform_test(filename, tmp_dir, timeout, spss \\ [], ppss \\ []) do
    in_path = "../fixtures/input-#{filename}.h264" |> Path.expand(__DIR__)
    out_path = Path.join(tmp_dir, "output-all-#{filename}.h264")

    assert {:ok, _supervisor_pid, pid} = make_pipeline(in_path, out_path, spss, ppss)
    assert_pipeline_play(pid)
    assert_end_of_stream(pid, :sink, :input, timeout)

    expected =
      if length(spss) > 0 and length(ppss) > 0 do
        Enum.join([<<>>] ++ spss ++ ppss, @prefix) <> File.read!(in_path)
      else
        File.read!(in_path)
      end

    assert File.read!(out_path) == expected

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

    test "process all 30 240p frames with provided sps and pps", ctx do
      sps =
        <<103, 100, 0, 50, 172, 114, 132, 64, 80, 5, 187, 1, 16, 0, 0, 3, 0, 16, 0, 0, 3, 3, 192,
          241, 131, 24, 70>>

      pps = <<104, 232, 67, 135, 75, 34, 192>>

      perform_test("30-240p-no-sps-pps", ctx.tmp_dir, 1000, [sps], [pps])
    end
  end
end
