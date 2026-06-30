defmodule Membrane.H26x.AUTimestampGeneratorTest do
  @moduledoc false
  use ExUnit.Case, async: true

  # A minimal generator that lets the test inject the POC and reorder-buffer depth
  # directly, so the buffering/ranking logic can be exercised independently of the
  # codec-specific POC calculation.
  defmodule FakeGenerator do
    @moduledoc false
    use Membrane.H26x.AUTimestampGenerator

    @impl true
    def max_frame_reorder(), do: 15

    @impl true
    def get_first_vcl_nalu(au), do: Enum.find(au, &(&1.parsed_fields[:poc] != nil))

    @impl true
    def calculate_poc(vcl_nalu, state), do: {vcl_nalu.parsed_fields.poc, state}

    @impl true
    def reorder_buffer_depth(vcl_nalu, _state), do: vcl_nalu.parsed_fields.depth
  end

  @second Membrane.Time.second()

  # Builds an access unit (a list with a single VCL NALu) carrying a given POC.
  # `depth` is read only when the AU starts a coded video sequence (poc == 0).
  defp au(poc, depth) do
    [%{parsed_fields: %{poc: poc, depth: depth}, status: :valid, timestamps: {nil, nil}}]
  end

  # Feeds the AUs (in decode order, all sharing the same reorder depth) through the
  # generator and flushes at the end, returning `[{poc, pts_in_frames, dts_in_frames}]`
  # in emission (decode) order.
  defp run(config, depth, pocs) do
    aus = Enum.map(pocs, &au(&1, depth))
    state = FakeGenerator.new(Map.merge(%{framerate: {1, 1}}, config))

    {emitted, _state} = FakeGenerator.generate_timestamps(aus, true, state)

    emitted
    |> Enum.map(fn au ->
      nalu = hd(au)
      {pts, dts} = nalu.timestamps
      {nalu.parsed_fields.poc, div(pts, @second), div(dts, @second)}
    end)
  end

  describe "generate_timestamps/3 with no reordering (depth 0)" do
    test "produces consecutive PTS even when POC advances by a step other than 1" do
      # POC stepping by 2 - the case the old implementation got wrong.
      result = run(%{add_dts_offset: false}, 0, [0, 2, 4, 6])

      assert result == [
               {0, 0, 0},
               {2, 1, 1},
               {4, 2, 2},
               {6, 3, 3}
             ]
    end

    test "handles a non-uniform monotonic POC sequence" do
      result = run(%{add_dts_offset: false}, 0, [0, 5, 6, 100])

      assert Enum.map(result, fn {_poc, pts, _dts} -> pts end) == [0, 1, 2, 3]
    end
  end

  describe "generate_timestamps/3 with reordering" do
    test "assigns PTS by presentation (POC) order while emitting in decode order" do
      # Decode order POCs: I=0, P=2, B=1 with reorder depth 1.
      result = run(%{add_dts_offset: false}, 1, [0, 2, 1])

      # Emitted in decode order, PTS reflects presentation rank (poc 0->0, 1->1, 2->2).
      assert result == [
               {0, 0, 0},
               {2, 2, 1},
               {1, 1, 2}
             ]
    end

    test "keeps PTS >= DTS for reordered frames when add_dts_offset is enabled" do
      result = run(%{add_dts_offset: true}, 2, [0, 4, 2, 1, 3])

      assert Enum.all?(result, fn {_poc, pts, dts} -> pts >= dts end)
      # PTS are the presentation ranks of the POCs.
      assert Enum.map(result, fn {poc, pts, _dts} -> {poc, pts} end) ==
               [{0, 0}, {4, 4}, {2, 2}, {1, 1}, {3, 3}]
    end

    test "emits every access unit exactly once" do
      pocs = [0, 8, 4, 2, 6, 1, 3, 5, 7]
      result = run(%{add_dts_offset: false}, 3, pocs)

      assert length(result) == length(pocs)
      assert result |> Enum.map(fn {poc, _pts, _dts} -> poc end) |> Enum.sort() == Enum.sort(0..8)
    end
  end

  describe "coded video sequence boundaries" do
    test "PTS keeps increasing across sequences and the previous sequence is flushed" do
      # Two GOPs (each I,P,B with depth 1); the second restarts POC at 0.
      result = run(%{add_dts_offset: false}, 1, [0, 2, 1, 0, 2, 1])

      # All six AUs come out in decode order with a continuous, per-presentation PTS.
      assert result == [
               {0, 0, 0},
               {2, 2, 1},
               {1, 1, 2},
               {0, 3, 3},
               {2, 5, 4},
               {1, 4, 5}
             ]
    end
  end

  describe "invalid access units" do
    test "passes through access units without a valid VCL NALu untouched" do
      state = FakeGenerator.new(%{framerate: {1, 1}, add_dts_offset: false})

      invalid_au = [%{parsed_fields: %{}, status: :error, timestamps: {nil, nil}}]
      {emitted, _state} = FakeGenerator.generate_timestamps([invalid_au], state)

      assert emitted == [invalid_au]
    end
  end
end
