defmodule Membrane.H264.TranscodingTest do
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
      |> child(:decoder, H264.FFmpeg.Decoder)
      |> child(:encoder, %H264.FFmpeg.Encoder{preset: :fast, crf: 30})
      |> child(:sink, %Membrane.File.Sink{location: out_path})
    ]

    Pipeline.start_link_supervised(structure: structure)
  end

  defp perform_test(filename, tmp_dir, timeout) do
    in_path = "../fixtures/input-#{filename}.h264" |> Path.expand(__DIR__)
    out_path = Path.join(tmp_dir, "output-transcode-#{filename}.h264")

    assert {:ok, _supervisor_pid, pid} = make_pipeline(in_path, out_path)
    assert_pipeline_play(pid)
    assert_end_of_stream(pid, :sink, :input, timeout)

    Pipeline.terminate(pid, blocking?: true)
  end

  describe "TranscodingPipeline should" do
    @describetag :tmp_dir
    test "transcode 10 720p frames", ctx do
      perform_test("10-720p", ctx.tmp_dir, 10_000)
    end

    test "transcode 100 240p frames", ctx do
      perform_test("100-240p", ctx.tmp_dir, 2000)
    end

    test "transcode 20 360p frames with 422 subsampling", ctx do
      perform_test("20-360p-I422", ctx.tmp_dir, 2000)
    end
  end
end
