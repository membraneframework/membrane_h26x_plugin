Mix.install([
  {:membrane_file_plugin, "~> 0.14.0"},
  {:membrane_hackney_plugin, "~> 0.10.0"},
  {:membrane_mp4_plugin, "~> 0.25.0"},
  {:membrane_mp4_format, ">= 0.0.0"},
  {:membrane_stream_plugin, "~> 0.3.1"},
  {:membrane_aac_plugin, ">= 0.0.0"},
  {:membrane_h264_format, path: "/Users/jakubpryc/Membrane/membrane_h264_format", override: true}
])

defmodule MP4ToH264Filter do
  use Membrane.Filter

  def_input_pad :input,
    demand_unit: :buffers,
    demand_mode: :auto,
    accepted_format: Membrane.MP4.Payload

  def_output_pad :output,
    demand_mode: :auto,
    accepted_format: Membrane.H264

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

  #  @impl true
  #  def handle_stream_format(
  #        :input,
  #        %Membrane.MP4.Payload{
  #          width: width,
  #          height: height,
  #          content: %Membrane.MP4.Payload.AVC1{avcc: <<dcr_header::binary-8*5, _rest::binary>>}
  #        },
  #        _ctx,
  #        state
  #      ) do
  #    IO.inspect(dcr_header)
  #    {[
  #      stream_format:
  #        {:output, %Membrane.H264{width: width, height: height, stream_type: {:avcc, <<dcr_header::binary, 0b111::3, 0::5, 0::8>>}}}
  #    ], state}
  #  end

  @impl true
  def handle_process(:input, buffer, _ctx, state) do
    {[buffer: {:output, buffer}], state}
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, state) do
    {[end_of_stream: :output], state}
  end
end

defmodule FixtureGenerator do
  use Membrane.Pipeline

  import Membrane.ChildrenSpec

  @mp4_fixture "../fixtures/mp4/ref_video_variable_parameters.mp4" |> Path.expand(__DIR__)
  @output_location "../fixtures/ref_video_variable_parameters-avc1.msf" |> Path.expand(__DIR__)

  @impl true
  def handle_init(_ctx, _opts) do
    structure = [
      child(:video_source, %Membrane.File.Source{location: @mp4_fixture})
      |> child(:demuxer, Membrane.MP4.Demuxer.ISOM)
      |> via_out(Pad.ref(:output, 1))
      |> child(:filter, MP4ToH264Filter)
      |> child(:serializer, Membrane.Stream.Serializer)
      |> child(:sink, %Membrane.File.Sink{location: @output_location})
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

{:ok, _supervisor_pid, pipeline_pid} = FixtureGenerator.start_link()
ref = Process.monitor(pipeline_pid)

receive do
  {:DOWN, ^ref, :process, _pipeline_pid, _reason} ->
    :ok
end
