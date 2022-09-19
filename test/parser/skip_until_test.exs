defmodule Membrane.H264.SkipUntilTest do
  @moduledoc false

  use ExUnit.Case
  import Membrane.Testing.Assertions
  alias Membrane.{H264, ParentSpec}
  alias Membrane.Testing.Pipeline

  defp make_pipeline(in_path, out_path) do
    children = [
      file_src: %Membrane.File.Source{chunk_size: 40_960, location: in_path},
      parser: H264.Parser,
      sink: %Membrane.File.Sink{location: out_path}
    ]

    Pipeline.start_link(links: ParentSpec.link_linear(children))
  end

  describe "The parser should" do
    @describetag :tmp_dir

    test "skip the whole stream if no pps/sps are provided", ctx do
      filename = "10-no-pps-sps"
      in_path = "../fixtures/input-#{filename}.h264" |> Path.expand(__DIR__)
      out_path = Path.join(ctx.tmp_dir, "output-all-#{filename}.h264")

      assert {:ok, pid} = make_pipeline(in_path, out_path)
      assert_pipeline_playback_changed(pid, :prepared, :playing)
      refute_sink_buffer(pid, :sink, _)

      Pipeline.terminate(pid, blocking?: true)
    end

    test "skip until IDR frame is provided", ctx do
      filename = "sps-pps-non-idr"
      in_path = "../fixtures/input-#{filename}.h264" |> Path.expand(__DIR__)
      out_path = Path.join(ctx.tmp_dir, "output-#{filename}.h264")
      ref_path = "test/fixtures/reference-#{filename}.h264"
      assert {:ok, pid} = make_pipeline(in_path, out_path)
      assert_pipeline_playback_changed(pid, :prepared, :playing)
      assert_end_of_stream(pid, :sink)
      assert File.read(out_path) == File.read(ref_path)
      Pipeline.terminate(pid, blocking?: true)
    end
  end
end
