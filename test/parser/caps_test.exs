defmodule Membrane.H264.StreamFormatTest do
  @moduledoc false

  use ExUnit.Case
  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions
  alias Membrane.H264
  alias Membrane.Testing.Pipeline

  defp make_pipeline(in_path) do
    structure = [
      child(:file_src, %Membrane.File.Source{chunk_size: 40_960, location: in_path})
      |> child(:parser, H264.Parser)
      |> child(:sink, Membrane.Testing.Sink)
    ]

    Pipeline.start_link_supervised(structure: structure)
  end

  @video_parameters %{
    "10-720p" => {:high, 1280, 720},
    "100-240p" => {:high, 320, 240},
    "20-360p-I422" => {:high_4_2_2, 480, 360},
    "10-720p-main" => {:main, 1280, 720},
    "10-720p-no-b-frames" => {:high, 1280, 720},
    "100-240p-no-b-frames" => {:high, 320, 240}
  }

  defp perform_test(filename, timeout) do
    in_path = Path.expand("../fixtures/input-#{filename}.h264", __DIR__)
    assert {:ok, _supervisor_pid, pid} = make_pipeline(in_path)
    {profile, width, height} = @video_parameters[filename]

    assert_sink_stream_format(pid, :sink, %H264{profile: ^profile, width: ^width, height: ^height})

    assert_pipeline_play(pid)
    assert_end_of_stream(pid, :sink, :input, timeout)

    Pipeline.terminate(pid, blocking?: true)
  end

  describe "Parser should" do
    test "read the proper stream format for: 10 720p frames" do
      perform_test("10-720p", 1000)
    end

    test "read the proper stream format for: 100 240p frames" do
      perform_test("100-240p", 1000)
    end

    test "read the proper stream format for: 20 360p frames with 422 subsampling" do
      perform_test("20-360p-I422", 1000)
    end

    test "read the proper stream format for: 10 720p frames with B frames in main profile" do
      perform_test("10-720p-main", 1000)
    end

    test "read the proper stream format for: 10 720p frames with no b frames" do
      perform_test("10-720p-no-b-frames", 10)
    end

    test "read the proper stream format for: 100 240p frames with no b frames" do
      perform_test("100-240p-no-b-frames", 100)
    end
  end
end
