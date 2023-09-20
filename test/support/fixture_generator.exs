Mix.install([
  {:membrane_file_plugin, "~> 0.15.0"},
  {:membrane_mp4_plugin, "~> 0.29.0"},
  {:membrane_stream_plugin, "~> 0.3.1"}
])

alias Membrane.H264.Parser.{NALuSplitter, DecoderConfigurationRecord}

defmodule Aligner do
  @moduledoc false

  use Membrane.Filter

  def_input_pad :input,
    demand_unit: :buffers,
    demand_mode: :auto,
    accepted_format: Membrane.H264

  def_output_pad :output,
    demand_mode: :auto,
    accepted_format: Membrane.H264

  def_options output_alignment: [
                spec: :au | :nalu,
                default: :au
              ],
              output_stream_structure: [
                spec: {:avc1 | :avc3, pos_integer()}
              ]

  @impl true
  def handle_stream_format(
        :input,
        %Membrane.H264{stream_structure: {:avc1, dcr}} = stream_format,
        _ctx,
        %{output_stream_structure: {avc, nalu_length_size}} = state
      ) do
    %{nalu_length_size: dcr_nalu_length_size} = DecoderConfigurationRecord.parse(dcr)

    if dcr_nalu_length_size != nalu_length_size do
      raise "incoming NALu length size must be equal to the one provided via options"
    end

    {[
       stream_format:
         {:output,
          %Membrane.H264{
            stream_format
            | alignment: state.output_alignment,
              stream_structure: {avc, dcr}
          }}
     ], state}
  end

  @impl true
  def handle_process(:input, buffer, _ctx, state) do
    buffers =
      case state.output_alignment do
        :au ->
          buffer

        :nalu ->
          splitter = NALuSplitter.new(state.output_stream_structure)
          {nalus, splitter} = NALuSplitter.split(buffer.payload, splitter)

          Enum.map(nalus, fn nalu -> %Membrane.Buffer{payload: nalu} end)
      end

    {[buffer: {:output, buffers}], state}
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, state) do
    {[end_of_stream: :output], state}
  end
end

defmodule FixtureGeneratorPipeline do
  @moduledoc false

  use Membrane.Pipeline

  import Membrane.ChildrenSpec

  @impl true
  def handle_init(_ctx, options) do
    structure = [
      child(:video_source, %Membrane.File.Source{location: options.input_location})
      |> child(:demuxer, Membrane.MP4.Demuxer.ISOM)
      |> via_out(Pad.ref(:output, 1))
      |> child(:filter, %Aligner{
        output_alignment: options.output_alignment,
        output_stream_structure: options.stream_structure
      })
      |> child(:serializer, Membrane.Stream.Serializer)
      |> child(:sink, %Membrane.File.Sink{location: options.output_location})
    ]

    {[spec: structure], %{children_with_eos: MapSet.new()}}
  end

  @impl true
  def handle_element_end_of_stream(element, _pad, _ctx, state) do
    state = %{state | children_with_eos: MapSet.put(state.children_with_eos, element)}

    actions =
      if :sink in state.children_with_eos,
        do: [terminate: :shutdown],
        else: []

    {actions, state}
  end
end

defmodule AVCFixtureGenerator do
  @moduledoc false

  @mp4_avc1_fixtures [
    "../fixtures/mp4/ref_video.mp4" |> Path.expand(__DIR__),
    "../fixtures/mp4/ref_video_fast_start.mp4" |> Path.expand(__DIR__)
  ]

  @mp4_avc3_fixtures [
    "../fixtures/mp4/ref_video.mp4" |> Path.expand(__DIR__),
    "../fixtures/mp4/ref_video_fast_start.mp4" |> Path.expand(__DIR__),
    "../fixtures/mp4/ref_video_variable_parameters.mp4" |> Path.expand(__DIR__)
  ]

  @spec generate_avc_fixtures() :: :ok
  def generate_avc_fixtures() do
    Enum.each(@mp4_avc1_fixtures, fn input_location ->
      generate_fixture(input_location, :au, {:avc1, 4})
      generate_fixture(input_location, :nalu, {:avc1, 4})
    end)

    Enum.each(@mp4_avc3_fixtures, fn input_location ->
      generate_fixture(input_location, :au, {:avc3, 4})
      generate_fixture(input_location, :nalu, {:avc3, 4})
    end)
  end

  defp generate_fixture(input_location, output_alignment, {avc, _} = stream_structure) do
    output_location =
      input_location
      |> Path.split()
      |> List.replace_at(-2, "msr")
      |> List.update_at(-1, fn file ->
        [name, "mp4"] = String.split(file, ".")
        "#{name}-#{avc}-#{output_alignment}.msr"
      end)
      |> Path.join()

    options = %{
      input_location: input_location,
      output_location: output_location,
      output_alignment: output_alignment,
      stream_structure: stream_structure
    }

    {:ok, _supervisor_pid, pipeline_pid} = FixtureGeneratorPipeline.start(options)
    ref = Process.monitor(pipeline_pid)

    receive do
      {:DOWN, ^ref, :process, _pipeline_pid, _reason} ->
        :ok
    end

    Membrane.Pipeline.terminate(pipeline_pid)
  end
end

AVCFixtureGenerator.generate_avc_fixtures()
