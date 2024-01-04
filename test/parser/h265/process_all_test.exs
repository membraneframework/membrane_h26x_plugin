defmodule Membrane.H265.ProcessAllTest do
  @moduledoc false

  use ExUnit.Case, async: true

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions

  alias Membrane.H265
  alias Membrane.Testing.Pipeline

  defp make_pipeline(in_path, out_path, parameter_sets) do
    spec = [
      child(:file_src, %Membrane.File.Source{chunk_size: 40_960, location: in_path})
      |> child(:parser, %H265.Parser{
        vpss: parameter_sets[:vpss] || [],
        spss: parameter_sets[:spss] || [],
        ppss: parameter_sets[:ppss] || []
      })
      |> child(:sink, %Membrane.File.Sink{location: out_path})
    ]

    Pipeline.start_link_supervised(spec: spec)
  end

  defp strip_parameter_sets(file) do
    data = File.read!(file)

    data
    |> :binary.matches([<<0, 0, 1>>, <<0, 0, 0, 1>>])
    |> Enum.chunk_every(2, 1, [{byte_size(data), nil}])
    |> Enum.map(fn [{from, _}, {to, _}] -> :binary.part(data, from, to - from) end)
    |> Enum.filter(fn
      <<0, 0, 1, 0::1, type::6, 0::1, _rest::binary>> when type in [32, 33, 34, 39] -> false
      <<0, 0, 0, 1, 0::1, type::6, 0::1, _rest::binary>> when type in [32, 33, 34, 39] -> false
      _other -> true
    end)
    |> Enum.join()
  end

  defp perform_test(
         filename,
         tmp_dir,
         timeout,
         parameter_sets \\ [],
         ignore_parameter_sets \\ false
       ) do
    in_path = "test/fixtures/h265/input-#{filename}.h265"
    out_path = Path.join(tmp_dir, "output-all-#{filename}.h265")

    assert {:ok, _supervisor_pid, pid} = make_pipeline(in_path, out_path, parameter_sets)
    assert_end_of_stream(pid, :sink, :input, timeout)

    if ignore_parameter_sets do
      assert strip_parameter_sets(out_path) == strip_parameter_sets(in_path)
    else
      assert File.read(out_path) == File.read(in_path)
    end

    Pipeline.terminate(pid)
  end

  describe "ProcessAllPipeline should" do
    @describetag :tmp_dir

    test "process all 10 320p frames with main still picture profile", ctx do
      perform_test("10-480x320-mainstillpicture", ctx.tmp_dir, 1000)
    end

    test "process all 10 480p frames with main 10 profile", ctx do
      perform_test("10-640x480-main10", ctx.tmp_dir, 1000)
    end

    test "process all 10 1080p frames", ctx do
      perform_test("10-1920x1080", ctx.tmp_dir, 1000)
    end

    test "process all 15 720p frames with more than one temporal sub-layer", ctx do
      perform_test("15-1280x720-temporal-id-1", ctx.tmp_dir, 1000)
    end

    test "process all 30 480p frames with no b frames", ctx do
      perform_test("30-640x480-no-bframes", ctx.tmp_dir, 1000)
    end

    test "process all 30 720p frames with rext profile", ctx do
      perform_test("30-1280x720-rext", ctx.tmp_dir, 1000)
    end

    test "process all 60 1080p frames", ctx do
      perform_test("60-1920x1080", ctx.tmp_dir, 1000)
    end

    test "process all 300 98p frames with conformance window", ctx do
      perform_test("300-98x58-conformance-window", ctx.tmp_dir, 1000)
    end

    test "process all 8 2K frames", ctx do
      # The bytestream contains AUD nalus and each access unit
      # has multiple slices
      perform_test("8-2K", ctx.tmp_dir, 1000)
    end

    test "process all 60 480p frames with provided parameter sets", ctx do
      vps =
        <<64, 1, 12, 1, 255, 255, 33, 96, 0, 0, 3, 0, 144, 0, 0, 3, 0, 0, 3, 0, 153, 149, 152, 9>>

      sps =
        <<66, 1, 1, 33, 96, 0, 0, 3, 0, 144, 0, 0, 3, 0, 0, 3, 0, 153, 160, 5, 2, 1, 225, 101,
          149, 154, 73, 50, 188, 57, 160, 32, 0, 0, 3, 0, 32, 0, 0, 3, 3, 193>>

      pps = <<68, 1, 193, 114, 180, 98, 64>>

      # Parameter sets without prefix
      perform_test(
        "60-640x480-no-parameter-sets",
        ctx.tmp_dir,
        1000,
        [vpss: [vps], spss: [sps], ppss: [pps]],
        true
      )
    end
  end
end
