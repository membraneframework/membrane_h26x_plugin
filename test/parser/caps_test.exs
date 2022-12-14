defmodule Membrane.H264.CapsTest do
  @moduledoc false

  use ExUnit.Case
  import Membrane.Testing.Assertions
  alias Membrane.{H264, ParentSpec}
  alias Membrane.Testing.Pipeline

  defp make_pipeline(in_path) do
    children = [
      file_src: %Membrane.File.Source{chunk_size: 40_960, location: in_path},
      parser: H264.Parser,
      sink: Membrane.Testing.Sink
    ]

    Pipeline.start_link(links: ParentSpec.link_linear(children))
  end

  @video_parameters %{
    "10-720p" => {:high, 1280, 720, {30, 1}},
    "100-240p" => {:high, 320, 240, {30, 1}},
    "20-360p-I422" => {:high_4_2_2, 480, 360, {30, 1}},
    "10-720p-main" => {:main, 1280, 720, {30, 1}},
    "10-720p-no-b-frames" => {:high, 1280, 720, {30, 1}},
    "100-240p-no-b-frames" => {:high, 320, 240, {30, 1}}
  }

  defp perform_test(filename, timeout) do
    in_path = Path.expand("../fixtures/input-#{filename}.h264", __DIR__)
    assert {:ok, pid} = make_pipeline(in_path)
    {profile, width, height, framerate} = @video_parameters[filename]

    assert_sink_caps(pid, :sink, %H264{
      profile: ^profile,
      width: ^width,
      height: ^height,
      framerate: ^framerate
    })

    assert_pipeline_playback_changed(pid, :prepared, :playing)
    assert_end_of_stream(pid, :sink, :input, timeout)

    Pipeline.terminate(pid, blocking?: true)
  end

  describe "Parser should" do
    test "read the proper caps for: 10 720p frames" do
      perform_test("10-720p", 1000)
    end

    test "read the proper caps for: 100 240p frames" do
      perform_test("100-240p", 1000)
    end

    test "read the proper caps for: 20 360p frames with 422 subsampling" do
      perform_test("20-360p-I422", 1000)
    end

    test "read the proper caps for: 10 720p frames with B frames in main profile" do
      perform_test("10-720p-main", 1000)
    end

    test "read the proper caps for: 10 720p frames with no b frames" do
      perform_test("10-720p-no-b-frames", 10)
    end

    test "read the proper caps for: 100 240p frames with no b frames" do
      perform_test("100-240p-no-b-frames", 100)
    end
  end
end
