defmodule Membrane.H26x.ParsingEngineTest do
  use ExUnit.Case, async: true

  alias Membrane.H26x.ParsingEngine
  alias Membrane.H26x.ParsingEngine.NALuSplitter

  test "parameter sets of a dropped access unit are attached to the next one, after its AUD" do
    payload = File.read!("test/fixtures/h264/input-10-720p.h264")

    {[aud, sps, pps, _sei, idr | rest], _splitter} =
      NALuSplitter.split(payload, true, NALuSplitter.new())

    malformed_idr = binary_part(idr, 0, 6)

    config = %{codec: :h264, input_alignment: :bytestream, input_stream_structure: :annexb}

    {events, _engine} =
      ParsingEngine.new(config)
      |> ParsingEngine.push(IO.iodata_to_binary([aud, sps, pps, malformed_idr | rest]))

    assert [{:parameter_sets, _parameter_sets}, {:access_unit, access_unit} | _events] = events
    assert [:aud, :sps, :pps, :non_idr] == Enum.map(access_unit.nalus, & &1.type)
    assert [sps, pps] == Enum.slice(access_unit.nalus_payloads, 1, 2)
    refute access_unit.keyframe?
  end
end
