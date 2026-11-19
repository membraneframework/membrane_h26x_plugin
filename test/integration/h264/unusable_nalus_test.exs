defmodule Membrane.H264.UnusableNALusTest do
  @moduledoc false

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions

  alias Membrane.Testing

  @stream File.read!("test/fixtures/h264/input-10-720p.h264")

  defp nalus() do
    @stream
    |> :binary.split([<<0, 0, 0, 1>>, <<0, 0, 1>>], [:global])
    |> Enum.reject(&(&1 == <<>>))
  end

  defp parse(nalus, parser_options \\ []) do
    pipeline =
      Testing.Pipeline.start_link_supervised!(
        spec:
          child(:source, %Testing.Source{
            output: Enum.map(nalus, &(<<0, 0, 0, 1>> <> &1)),
            stream_format: %Membrane.H264{alignment: :nalu, stream_structure: :annexb}
          })
          |> child(:parser, struct!(Membrane.H264.Parser, parser_options))
          |> child(:sink, Testing.Sink)
      )

    assert_end_of_stream(pipeline, :sink, :input, 5_000)
    Testing.Pipeline.terminate(pipeline)
    count_buffers(pipeline)
  end

  defp count_buffers(pipeline, count \\ 0) do
    receive do
      {Testing.Pipeline, ^pipeline, {:handle_child_notification, {{:buffer, _buffer}, :sink}}} ->
        count_buffers(pipeline, count + 1)
    after
      0 -> count
    end
  end

  setup_all do
    %{access_units: parse(nalus())}
  end

  test "a parameter set given in the options that cannot be parsed does not stop the stream",
       %{access_units: access_units} do
    for options <- [
          [spss: [<<0x67, 1, 2>>]],
          [ppss: [<<0x68>>]],
          [spss: [<<0x67, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF>>], ppss: [<<0x68, 0xFF>>]]
        ] do
      {parsed, log} = with_log(fn -> parse(nalus(), options) end)

      assert parsed == access_units
      assert log =~ "Ignoring a parameter set that cannot be parsed"
    end
  end

  test "a parameter set in the stream that cannot be parsed does not stop the stream",
       %{access_units: access_units} do
    {head, tail} = Enum.split(nalus(), 20)

    {parsed, log} =
      with_log(fn ->
        parse(head ++ [<<0x67, 1, 2>>, <<0x68>>] ++ tail, skip_until_keyframe: false)
      end)

    assert parsed in (access_units - 2)..(access_units - 1)
    assert log =~ "Failed to parse a sps NALu"
    assert log =~ "Dropping an access unit containing NALus that failed to parse"
  end

  test "an empty NAL unit is ignored", %{access_units: access_units} do
    {head, tail} = Enum.split(nalus(), 20)

    {parsed, log} = with_log(fn -> parse([<<>>] ++ head ++ [<<>>] ++ tail) end)

    assert parsed == access_units

    assert [_first, _second, _rest] =
             String.split(log, "Ignoring a NALu too short to hold a header")

    assert [_before, _after] = String.split(log, "Further ones will be logged at the debug level")
  end
end
