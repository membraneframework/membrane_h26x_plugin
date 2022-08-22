defmodule Membrane.H264.TranscodingTest do
  @moduledoc false

  use ExUnit.Case
  import Membrane.Testing.Assertions
  alias Membrane.{H264, ParentSpec}
  alias Membrane.Testing.Pipeline

  @caps %H264{
    alignment: :au,
    framerate: {0, 1},
    height: 720,
    nalu_in_metadata?: false,
    profile: :high,
    stream_format: :byte_stream,
    width: 1280
  }

  defp make_pipeline(in_path, out_path, caps) do
    children = [
      file_src: %Membrane.File.Source{chunk_size: 40_960, location: in_path},
      # parser: %H264.Parser{caps: caps},
      parser: H264.Parser,
      decoder: H264.FFmpeg.Decoder,
      encoder: %H264.FFmpeg.Encoder{preset: :fast, crf: 30},
      sink: %Membrane.File.Sink{location: out_path}
    ]

    Pipeline.start_link(links: ParentSpec.link_linear(children))
  end

  defp perform_test(filename, tmp_dir, timeout, caps \\ @caps) do
    in_path = "../fixtures/input-#{filename}.h264" |> Path.expand(__DIR__)
    out_path = Path.join(tmp_dir, "output-transcode-#{filename}.h264")

    assert {:ok, pid} = make_pipeline(in_path, out_path, caps)
    assert_pipeline_playback_changed(pid, :prepared, :playing)
    assert_end_of_stream(pid, :sink, :input, timeout)

    Pipeline.terminate(pid, blocking?: true)
  end

  describe "TranscodingPipeline should" do
    @describetag :tmp_dir
    test "transcode 10 720p frames", ctx do
      perform_test("10-720p", ctx.tmp_dir, 10000)
    end

    test "transcode 100 240p frames", ctx do
      caps =
        @caps
        |> Map.put(:height, 240)
        |> Map.put(:height, 360)

      perform_test("100-240p", ctx.tmp_dir, 2000, caps)
    end

    test "transcode 20 360p frames with 422 subsampling", ctx do
      caps =
        @caps
        |> Map.put(:height, 240)
        |> Map.put(:height, 360)
        |> Map.put(:profile, :high_422)

      perform_test("20-360p-I422", ctx.tmp_dir, 2000, caps)
    end
  end
end
