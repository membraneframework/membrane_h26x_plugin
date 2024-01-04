defmodule Membrane.H26x.Support.TestSource do
  @moduledoc false

  use Membrane.Source

  def_options mode: [],
              output_raw_stream_structure: [default: :annexb],
              codec: [default: :H264]

  def_output_pad :output,
    flow_control: :push,
    accepted_format:
      any_of(
        %Membrane.RemoteStream{type: :bytestream},
        %Membrane.H264{alignment: alignment} when alignment in [:au, :nalu],
        %Membrane.H265{alignment: alignment} when alignment in [:au, :nalu]
      )

  @impl true
  def handle_init(_ctx, opts) do
    {[],
     %{
       mode: opts.mode,
       codec: opts.codec,
       output_raw_stream_structure: opts.output_raw_stream_structure
     }}
  end

  @impl true
  def handle_parent_notification(actions, _ctx, state) do
    {actions, state}
  end

  @impl true
  def handle_playing(_ctx, state) do
    stream_format =
      case {state.codec, state.mode} do
        {_codec, :bytestream} ->
          %Membrane.RemoteStream{type: :bytestream}

        {:H264, :nalu_aligned} ->
          %Membrane.H264{alignment: :nalu, stream_structure: state.output_raw_stream_structure}

        {:H264, :au_aligned} ->
          %Membrane.H264{alignment: :au, stream_structure: state.output_raw_stream_structure}

        {:H265, :nalu_aligned} ->
          %Membrane.H265{alignment: :nalu, stream_structure: state.output_raw_stream_structure}

        {:H265, :au_aligned} ->
          %Membrane.H265{alignment: :au, stream_structure: state.output_raw_stream_structure}
      end

    {[stream_format: {:output, stream_format}], state}
  end
end
