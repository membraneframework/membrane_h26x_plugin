Mix.install([
  {:membrane_file_plugin, "~> 0.14.0"},
  {:membrane_hackney_plugin, "~> 0.10.0"},
  {:membrane_mp4_plugin, "~> 0.25.0"},
  {:membrane_mp4_format, ">= 0.0.0"},
  {:membrane_stream_plugin, "~> 0.3.1"},
  {:membrane_aac_plugin, ">= 0.0.0"},
  {:membrane_h264_format, path: "/Users/jakubpryc/Membrane/membrane_h264_format", override: true}
])

alias Membrane.H264.Parser.NALuSplitter

defmodule MP4ToH264Filter do
  use Membrane.Filter

  def_input_pad :input,
    demand_unit: :buffers,
    demand_mode: :auto,
    accepted_format: Membrane.MP4.Payload

  def_output_pad :output,
    demand_mode: :auto,
    accepted_format: Membrane.H264

  def_options output_alignment: [
                spec: :au | :nalu,
                default: :au
              ]

  @impl true
  def handle_init(_ctx, opts) do
    {[], %{output_alignment: opts.output_alignment}}
  end

  @impl true
  def handle_stream_format(
        :input,
        %Membrane.MP4.Payload{
          width: width,
          height: height,
          content: %Membrane.MP4.Payload.AVC1{avcc: dcr}
        },
        _ctx,
        state
      ) do
    {[
       stream_format:
         {:output,
          %Membrane.H264{
            width: width,
            height: height,
            stream_type: {:avc1, dcr}
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
          {nalus, splitter} =
            NALuSplitter.split(buffer.payload, NALuSplitter.new())

          nalus = nalus ++ [elem(NALuSplitter.flush(splitter), 0)]
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
  use Membrane.Pipeline

  import Membrane.ChildrenSpec

  @mp4_fixture "../fixtures/mp4/ref_video_variable_parameters.mp4" |> Path.expand(__DIR__)
  @output_location "../fixtures/ref_video_variable_parameters-avc1.msf" |> Path.expand(__DIR__)

  @impl true
  def handle_init(_ctx, options) do
    IO.inspect(options)
    structure = [
      child(:video_source, %Membrane.File.Source{location: options.input_location})
      |> child(:demuxer, Membrane.MP4.Demuxer.ISOM)
      |> via_out(Pad.ref(:output, 1))
      |> child(:filter, %MP4ToH264Filter{output_alignment: options.output_alignment})
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

defmodule FixtureGenerator do
  def generate_avc1_fixture(input_location, output_alignment) do
    output_location =
      input_location
      |> Path.split()
      |> List.replace_at(-2, "msf")
      |> List.update_at(-1, fn file ->
        [name, "mp4"] = String.split(file, ".")
        "#{name}-avc1-#{output_alignment}.msf"
      end)
      |> Path.join()

    options = %{
      input_location: input_location,
      output_location: output_location,
      output_alignment: output_alignment
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


Enum.each("../fixtures/mp4/*.mp4" |> Path.expand(__DIR__) |> Path.wildcard(), fn input_location ->
  FixtureGenerator.generate_avc1_fixture(input_location, :au)
  FixtureGenerator.generate_avc1_fixture(input_location, :nalu)
end)

