defmodule Membrane.H26x.ParsingEngine.AUDTSInfererTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Membrane.H26x.ParsingEngine
  alias Membrane.H26x.ParsingEngine.AUDTSInferer

  defmodule FakeGenerator do
    @moduledoc false

    @spec get_first_vcl_nalu([map()]) :: map() | nil
    def get_first_vcl_nalu(au), do: List.first(au)

    @spec calculate_poc(map(), map()) :: {integer(), map()}
    def calculate_poc(vcl_nalu, state), do: {vcl_nalu.parsed_fields.poc, state}
  end

  defp au(type, poc, pts, dts \\ nil) do
    [
      %{
        type: type,
        parsed_fields: %{poc: poc},
        status: :valid,
        timestamps: {pts, dts}
      }
    ]
  end

  defp infer(access_units) do
    {timestamped, _state} =
      AUDTSInferer.infer_timestamps(FakeGenerator, access_units, AUDTSInferer.new())

    Enum.map(timestamped, fn {au, pts, dts} -> {hd(au).parsed_fields.poc, pts, dts} end)
  end

  test "infers monotonic DTS while preserving reordered PTS" do
    assert infer([
             au(:idr_w_radl, 0, 0),
             au(:trail_r, 2, 2_000),
             au(:trail_n, 1, 1_000),
             au(:trail_r, 3, 3_000)
           ]) == [
             {0, 0, 0},
             {2, 2_000, 1_000},
             {1, 1_000, 2_000},
             {3, 3_000, 3_000}
           ]
  end

  test "keeps PTS and DTS equal when pictures are already in presentation order" do
    assert infer([
             au(:idr_w_radl, 0, 0),
             au(:trail_r, 1, 1_000),
             au(:trail_r, 2, 2_000)
           ]) == [
             {0, 0, 0},
             {1, 1_000, 1_000},
             {2, 2_000, 2_000}
           ]
  end

  test "infers cadence for an all-intra stream" do
    assert infer([
             au(:idr_w_radl, 0, 0),
             au(:idr_w_radl, 0, 1_000),
             au(:idr_w_radl, 0, 2_000)
           ]) == [
             {0, 0, 0},
             {0, 1_000, 1_000},
             {0, 2_000, 2_000}
           ]
  end

  test "starts a new timing epoch on a random-access picture" do
    assert infer([
             au(:idr_w_radl, 0, 0),
             au(:trail_r, 2, 2_000),
             au(:trail_n, 1, 1_000),
             au(:idr_w_radl, 0, 3_000),
             au(:trail_r, 2, 5_000),
             au(:trail_n, 1, 4_000)
           ]) == [
             {0, 0, 0},
             {2, 2_000, 1_000},
             {1, 1_000, 2_000},
             {0, 3_000, 3_000},
             {2, 5_000, 4_000},
             {1, 4_000, 5_000}
           ]
  end

  test "reanchors DTS after a forward timestamp discontinuity" do
    assert infer([
             au(:idr_w_radl, 0, 0),
             au(:trail_r, 1, 1_000),
             au(:idr_w_radl, 0, 10_000),
             au(:trail_r, 1, 11_000)
           ]) == [
             {0, 0, 0},
             {1, 1_000, 1_000},
             {0, 10_000, 10_000},
             {1, 11_000, 11_000}
           ]
  end

  test "preserves a stream that supplies DTS" do
    assert infer([
             au(:trail_r, 2, 2_000, 1_000),
             au(:trail_n, 1, 1_000, 2_000)
           ]) == [
             {2, 2_000, 1_000},
             {1, 1_000, 2_000}
           ]
  end

  test "requires a random-access timing anchor" do
    assert_raise ArgumentError, ~r/does not start with a random-access picture/, fn ->
      infer([au(:trail_r, 0, 0)])
    end
  end

  test "requires PTS in inference mode" do
    assert_raise ArgumentError, ~r/access unit is missing PTS/, fn ->
      infer([au(:idr_w_radl, 0, 0), au(:trail_r, 1, nil)])
    end
  end

  test "rejects mixed DTS availability" do
    assert_raise ArgumentError, ~r/supplied DTS appeared/, fn ->
      infer([au(:idr_w_radl, 0, 0), au(:trail_r, 1, 1_000, 1_000)])
    end

    assert_raise ArgumentError, ~r/DTS disappeared/, fn ->
      infer([au(:trail_r, 0, 0, 0), au(:trail_r, 1, 1_000)])
    end
  end

  test "rejects an invalid cadence" do
    assert_raise ArgumentError, ~r/positive frame duration/, fn ->
      infer([au(:idr_w_radl, 0, 0), au(:trail_r, 1, -1_000)])
    end
  end

  test "rejects incompatible parser timestamp options" do
    base_config = %{
      codec: :h265,
      input_alignment: :au,
      input_stream_structure: :annexb
    }

    assert_raise ArgumentError, ~r/cannot be combined/, fn ->
      ParsingEngine.new(
        Map.merge(base_config, %{
          infer_dts_from_pts: true,
          generate_best_effort_timestamps: %{framerate: {30, 1}}
        })
      )
    end

    assert_raise ArgumentError, ~r/only supported for H265/, fn ->
      ParsingEngine.new(Map.merge(base_config, %{codec: :h264, infer_dts_from_pts: true}))
    end
  end
end
