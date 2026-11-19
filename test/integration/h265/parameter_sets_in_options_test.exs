defmodule Membrane.H265.ParameterSetsInOptionsTest do
  @moduledoc false

  use ExUnit.Case, async: true

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions

  alias Membrane.Testing

  @stream File.read!("test/fixtures/h265/input-10-1920x1080.h265")

  defp nalus() do
    @stream
    |> :binary.split([<<0, 0, 0, 1>>, <<0, 0, 1>>], [:global])
    |> Enum.reject(&(&1 == <<>>))
  end

  defp type(<<_forbidden::1, type::6, _rest::bitstring>>), do: type

  defp parse(nalus, parser_options) do
    pipeline =
      Testing.Pipeline.start_link_supervised!(
        spec:
          child(:source, %Testing.Source{
            output: Enum.map(nalus, &(<<0, 0, 0, 1>> <> &1)),
            stream_format: %Membrane.H265{alignment: :nalu, stream_structure: :annexb}
          })
          |> child(:parser, struct!(Membrane.H265.Parser, parser_options))
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

  test "parameter sets given in the options with start codes around them are used without them" do
    access_units = parse(nalus(), [])
    assert access_units > 0

    {parameter_sets, rest} = Enum.split_with(nalus(), &(type(&1) in 32..34))
    sets = fn type -> parameter_sets |> Enum.filter(&(type(&1) == type)) |> Enum.uniq() end

    for wrap <- [
          &(<<0, 0, 0, 1>> <> &1),
          &(&1 <> <<0, 0, 0, 1>>),
          &(<<0, 0, 1>> <> &1 <> <<0, 0, 1>>)
        ] do
      options = [
        vpss: Enum.map(sets.(32), wrap),
        spss: Enum.map(sets.(33), wrap),
        ppss: Enum.map(sets.(34), wrap)
      ]

      {parsed, log} = ExUnit.CaptureLog.with_log(fn -> parse(rest, options) end)

      assert parsed == access_units
      assert log =~ "Removed an Annex B start code from a parameter set"
    end
  end
end
