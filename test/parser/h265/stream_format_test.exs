defmodule Membrane.H265.StreamFormatTest do
  @moduledoc false

  use ExUnit.Case
  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions
  alias Membrane.H265
  alias Membrane.Testing.Pipeline

  defp make_pipeline(in_path) do
    spec = [
      child(:file_src, %Membrane.File.Source{chunk_size: 40_960, location: in_path})
      |> child(:parser, H265.Parser)
      |> child(:sink, Membrane.Testing.Sink)
    ]

    Pipeline.start_link_supervised(spec: spec)
  end

  @video_parameters %{
    "15-1280x720-temporal-id-1" => {:main, 1280, 720},
    "30-640x480-no-bframes" => {:main, 640, 480},
    "30-1280x720-rext" => {:rext, 1280, 720},
    "60-640x480" => {:main, 640, 480},
    "60-1920x1080" => {:main, 1920, 1080},
    "10-640x480-main10" => {:main_10, 640, 480},
    "10-480x320-mainstillpicture" => {:main_still_picture, 480, 320},
    "300-98x58-conformance-window" => {:main, 98, 58}
  }

  defp perform_test(filename, timeout) do
    in_path = Path.expand("../../fixtures/h265/input-#{filename}.h265", __DIR__)
    assert {:ok, _supervisor_pid, pid} = make_pipeline(in_path)
    {profile, width, height} = @video_parameters[filename]

    assert_sink_stream_format(pid, :sink, %H265{profile: ^profile, width: ^width, height: ^height})

    assert_sink_playing(pid, :sink)
    assert_end_of_stream(pid, :sink, :input, timeout)

    Pipeline.terminate(pid)
  end

  describe "Parser should" do
    test "read the proper stream format for: 15 720p frames with more than one temporal sub-layer" do
      perform_test("15-1280x720-temporal-id-1", 1000)
    end

    test "read the proper stream format for: 30 480p frames" do
      perform_test("30-640x480-no-bframes", 1000)
    end

    test "read the proper stream format for: 30 720p with rext profile" do
      perform_test("30-1280x720-rext", 1000)
    end

    test "read the proper stream format for: 60 480p frames" do
      perform_test("60-640x480", 1000)
    end

    test "read the proper stream format for: 60 1080p frames" do
      perform_test("60-1920x1080", 10)
    end

    test "read the proper stream format for: 10 480p frames with main 10 profile" do
      perform_test("10-640x480-main10", 100)
    end

    test "read the proper stream format for: 10 320p frames with main still picture profile" do
      perform_test("10-480x320-mainstillpicture", 100)
    end

    test "read the proper stream format for: 300 98p frames with main profile and conformance window" do
      perform_test("300-98x58-conformance-window", 100)
    end
  end
end
