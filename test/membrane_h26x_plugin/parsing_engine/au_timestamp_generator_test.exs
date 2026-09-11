defmodule Membrane.H26x.ParsingEngine.AUTimestampGeneratorTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Membrane.H26x.ParsingEngine
  alias Membrane.H26x.ParsingEngine.AUTimestampGenerator

  defmodule FakeGenerator do
    @moduledoc false
    @behaviour Membrane.H26x.ParsingEngine.AUTimestampGenerator

    @impl true
    def max_frame_reorder(), do: 15

    @impl true
    def get_first_vcl_nalu(au), do: Enum.find(au, &(&1.parsed_fields[:poc] != nil))

    @impl true
    def calculate_poc(vcl_nalu, state), do: {vcl_nalu.parsed_fields.poc, state}

    @impl true
    def reorder_buffer_depth(vcl_nalu, _state), do: vcl_nalu.parsed_fields.depth

    @impl true
    def random_access?(vcl_nalu), do: vcl_nalu.parsed_fields.random_access?
  end

  defp au(poc, depth) do
    [%{parsed_fields: %{poc: poc, depth: depth}, status: :valid, timestamps: {nil, nil}}]
  end

  # Returns `[{POC, PTS, DTS}]` in decode order
  defp run(config, depth, pocs) do
    aus = Enum.map(pocs, &au(&1, depth))

    state =
      AUTimestampGenerator.new(
        FakeGenerator,
        :generate_best_effort_timestamps,
        Map.merge(%{framerate: {1, 1}}, config)
      )

    {emitted, _state} =
      AUTimestampGenerator.generate_timestamps(FakeGenerator, aus, [flush?: true], state)

    emitted
    |> Enum.map(fn {au, pts, dts} ->
      nalu = hd(au)

      {nalu.parsed_fields.poc, Membrane.Time.as_seconds(pts, :round),
       Membrane.Time.as_seconds(dts, :round)}
    end)
  end

  describe "best-effort generation with no reordering (depth 0)" do
    test "produces consecutive PTS even when POC advances by a step other than 1" do
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

  describe "best-effort generation with reordering" do
    test "assigns PTS by presentation (POC) order while emitting in decode order" do
      result = run(%{add_dts_offset: false}, 1, [0, 2, 1])

      assert result == [
               {0, 0, 0},
               {2, 2, 1},
               {1, 1, 2}
             ]
    end

    test "keeps PTS >= DTS for reordered frames when add_dts_offset is enabled" do
      result = run(%{add_dts_offset: true}, 2, [0, 4, 2, 1, 3])
      assert Enum.all?(result, fn {_poc, pts, dts} -> pts >= dts end)

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

  describe "best-effort coded video sequence boundaries" do
    test "PTS keeps increasing across sequences and the previous sequence is flushed" do
      result = run(%{add_dts_offset: false}, 1, [0, 2, 1, 0, 2, 1])

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

  describe "best-effort invalid access units" do
    test "passes through access units without a valid VCL NALu untouched" do
      state =
        AUTimestampGenerator.new(FakeGenerator, :generate_best_effort_timestamps, %{
          framerate: {1, 1},
          add_dts_offset: false
        })

      invalid_au = [%{parsed_fields: %{}, status: :error, timestamps: {nil, nil}}]

      {emitted, _state} =
        AUTimestampGenerator.generate_timestamps(FakeGenerator, [invalid_au], state)

      assert emitted == [{invalid_au, nil, nil}]
    end
  end

  defp inference_au(random_access?, poc, pts, dts \\ nil) do
    [
      %{
        parsed_fields: %{poc: poc, random_access?: random_access?, depth: 0},
        status: :valid,
        timestamps: {pts, dts}
      }
    ]
  end

  defp infer(access_units) do
    {timestamped, _state} =
      AUTimestampGenerator.generate_timestamps(
        FakeGenerator,
        access_units,
        AUTimestampGenerator.new(FakeGenerator, :infer_dts_from_pts)
      )

    Enum.map(timestamped, fn {au, pts, dts} -> {hd(au).parsed_fields.poc, pts, dts} end)
  end

  describe "DTS inference" do
    test "infers monotonic DTS while preserving reordered PTS" do
      assert infer([
               inference_au(true, 0, 0),
               inference_au(false, 2, 2_000),
               inference_au(false, 1, 1_000),
               inference_au(false, 3, 3_000)
             ]) == [
               {0, 0, 0},
               {2, 2_000, 1_000},
               {1, 1_000, 2_000},
               {3, 3_000, 3_000}
             ]
    end

    test "keeps PTS and DTS equal when pictures are already in presentation order" do
      assert infer([
               inference_au(true, 0, 0),
               inference_au(false, 1, 1_000),
               inference_au(false, 2, 2_000)
             ]) == [
               {0, 0, 0},
               {1, 1_000, 1_000},
               {2, 2_000, 2_000}
             ]
    end

    test "infers cadence for an all-intra stream" do
      assert infer([
               inference_au(true, 0, 0),
               inference_au(true, 0, 1_000),
               inference_au(true, 0, 2_000)
             ]) == [
               {0, 0, 0},
               {0, 1_000, 1_000},
               {0, 2_000, 2_000}
             ]
    end

    test "starts a new timing epoch on a random-access picture" do
      assert infer([
               inference_au(true, 0, 0),
               inference_au(false, 2, 2_000),
               inference_au(false, 1, 1_000),
               inference_au(true, 0, 3_000),
               inference_au(false, 2, 5_000),
               inference_au(false, 1, 4_000)
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
               inference_au(true, 0, 0),
               inference_au(false, 1, 1_000),
               inference_au(true, 0, 10_000),
               inference_au(false, 1, 11_000)
             ]) == [
               {0, 0, 0},
               {1, 1_000, 1_000},
               {0, 10_000, 10_000},
               {1, 11_000, 11_000}
             ]
    end

    test "preserves a stream that supplies DTS" do
      assert infer([
               inference_au(false, 2, 2_000, 1_000),
               inference_au(false, 1, 1_000, 2_000)
             ]) == [
               {2, 2_000, 1_000},
               {1, 1_000, 2_000}
             ]
    end

    test "requires a random-access timing anchor" do
      assert_raise ArgumentError, ~r/does not start with a random-access picture/, fn ->
        infer([inference_au(false, 0, 0)])
      end
    end

    test "requires PTS in inference mode" do
      assert_raise ArgumentError, ~r/access unit is missing PTS/, fn ->
        infer([inference_au(true, 0, 0), inference_au(false, 1, nil)])
      end
    end

    test "rejects mixed DTS availability" do
      assert_raise ArgumentError, ~r/supplied DTS appeared/, fn ->
        infer([inference_au(true, 0, 0), inference_au(false, 1, 1_000, 1_000)])
      end

      assert_raise ArgumentError, ~r/DTS disappeared/, fn ->
        infer([inference_au(false, 0, 0, 0), inference_au(false, 1, 1_000)])
      end
    end

    test "rejects an invalid cadence" do
      assert_raise ArgumentError, ~r/positive frame duration/, fn ->
        infer([inference_au(true, 0, 0), inference_au(false, 1, -1_000)])
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

  describe "passthrough" do
    test "preserves supplied and missing timestamps without selecting a DTS source" do
      state = AUTimestampGenerator.new(FakeGenerator, :passthrough)

      access_units = [
        inference_au(false, 0, nil),
        inference_au(false, 1, 2_000, -1_000),
        inference_au(false, 2, 1_000),
        inference_au(false, 3, nil, 3_000)
      ]

      {emitted, ^state} =
        AUTimestampGenerator.generate_timestamps(FakeGenerator, access_units, state)

      assert Enum.map(emitted, fn {_au, pts, dts} -> {pts, dts} end) ==
               [{nil, nil}, {2_000, -1_000}, {1_000, nil}, {nil, 3_000}]

      assert {[], ^state} =
               AUTimestampGenerator.generate_timestamps(FakeGenerator, [], [flush?: true], state)
    end

    test "uses the first VCL timestamps even in invalid access units" do
      state = AUTimestampGenerator.new(FakeGenerator, :passthrough)
      non_vcl = %{parsed_fields: %{}, status: :error, timestamps: {9, 8}}
      [vcl] = inference_au(false, 0, 2, 1)
      access_unit = [non_vcl, vcl, %{vcl | timestamps: {4, 3}}]

      assert {[{^access_unit, 2, 1}, {[^non_vcl], nil, nil}, {[], nil, nil}], ^state} =
               AUTimestampGenerator.generate_timestamps(
                 FakeGenerator,
                 [access_unit, [non_vcl], []],
                 state
               )
    end
  end

  describe "DTS inference state across calls" do
    test "ignores invalid access units before and after selecting inferred DTS" do
      state = AUTimestampGenerator.new(FakeGenerator, :infer_dts_from_pts)
      non_vcl = [%{parsed_fields: %{}, status: :valid, timestamps: {10, 10}}]
      invalid_vcl = Enum.map(inference_au(false, 1, 1_000, 1_000), &%{&1 | status: :error})
      invalid_aus = [non_vcl, invalid_vcl, []]
      expected_invalid = Enum.map(invalid_aus, &{&1, nil, nil})

      assert {^expected_invalid, ^state} =
               AUTimestampGenerator.generate_timestamps(FakeGenerator, invalid_aus, state)

      anchor = inference_au(true, 0, 0)

      {[{^anchor, 0, 0}], state} =
        AUTimestampGenerator.generate_timestamps(FakeGenerator, [anchor], state)

      assert {^expected_invalid, ^state} =
               AUTimestampGenerator.generate_timestamps(FakeGenerator, invalid_aus, state)

      assert {[], ^state} =
               AUTimestampGenerator.generate_timestamps(FakeGenerator, [], [flush?: true], state)

      next = inference_au(false, 2, 2_000)

      {[{^next, 2_000, 1_000}], state} =
        AUTimestampGenerator.generate_timestamps(FakeGenerator, [next], state)

      reordered = inference_au(false, 1, 1_000)

      assert {[{^reordered, 1_000, 2_000}], _state} =
               AUTimestampGenerator.generate_timestamps(
                 FakeGenerator,
                 [reordered],
                 [flush?: true],
                 state
               )
    end

    test "retains supplied DTS validation after flushing" do
      state = AUTimestampGenerator.new(FakeGenerator, :infer_dts_from_pts)

      {[_au], state} =
        AUTimestampGenerator.generate_timestamps(
          FakeGenerator,
          [inference_au(false, 0, nil, 0)],
          state
        )

      {[], state} =
        AUTimestampGenerator.generate_timestamps(FakeGenerator, [], [flush?: true], state)

      assert_raise ArgumentError, ~r/DTS disappeared/, fn ->
        AUTimestampGenerator.generate_timestamps(
          FakeGenerator,
          [inference_au(false, 1, 1_000)],
          state
        )
      end
    end

    test "uses codec reorder depth to retain cadence at random-access pictures" do
      [anchor] = inference_au(true, 0, 5_000)
      anchor = %{anchor | parsed_fields: %{anchor.parsed_fields | depth: 2}}

      assert infer([inference_au(true, 0, 0), inference_au(false, 1, 1_000), [anchor]]) ==
               [{0, 0, 0}, {1, 1_000, 1_000}, {0, 5_000, 2_000}]
    end

    test "rejects missing initial timestamps and invalid random-access epochs" do
      assert_raise ArgumentError, ~r/neither PTS nor DTS/, fn ->
        infer([inference_au(true, 0, nil)])
      end

      assert_raise ArgumentError, ~r/consecutive random-access pictures/, fn ->
        infer([inference_au(true, 0, 0), inference_au(true, 0, 0)])
      end

      assert_raise ArgumentError, ~r/non-monotonic timing epoch/, fn ->
        infer([
          inference_au(true, 0, 0),
          inference_au(false, 1, 1_000),
          inference_au(true, 0, -10_000)
        ])
      end
    end
  end

  describe "input alignment" do
    test "aligned input preserves timestamps and best-effort state" do
      state =
        AUTimestampGenerator.new(FakeGenerator, :generate_best_effort_timestamps, %{
          framerate: {1, 1}
        })

      access_unit = inference_au(false, 0, 2_000, 1_000)

      for alignment <- [:au, :nalu] do
        assert {[{^access_unit, 2_000, 1_000}], ^state} =
                 AUTimestampGenerator.generate_timestamps(
                   FakeGenerator,
                   [access_unit],
                   [input_alignment: alignment, flush?: true],
                   state
                 )
      end
    end

    test "inference operates on every input alignment" do
      state = AUTimestampGenerator.new(FakeGenerator, :infer_dts_from_pts)
      access_units = [inference_au(true, 0, 0), inference_au(false, 2, 2_000)]

      for alignment <- [:bytestream, :au, :nalu] do
        {emitted, _state} =
          AUTimestampGenerator.generate_timestamps(
            FakeGenerator,
            access_units,
            [input_alignment: alignment, flush?: true],
            state
          )

        assert Enum.map(emitted, fn {_au, pts, dts} -> {pts, dts} end) == [{0, 0}, {2_000, 1_000}]
      end
    end
  end
end
