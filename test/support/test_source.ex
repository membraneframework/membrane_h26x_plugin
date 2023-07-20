defmodule Membrane.H264.Support.TestSource do
  @moduledoc false

  use Membrane.Source

  def_options mode: [],
              output_raw_stream_type: [default: :annexb]

  def_output_pad :output,
    mode: :push,
    accepted_format:
      any_of(
        %Membrane.RemoteStream{type: :bytestream},
        %Membrane.H264.RemoteStream{alignment: alignment} when alignment in [:au, :nalu]
      )

  @impl true
  def handle_init(_ctx, opts) do
    {[], %{mode: opts.mode, output_raw_stream_type: opts.output_raw_stream_type}}
  end

  @impl true
  def handle_parent_notification(actions, _ctx, state) do
    {actions, state}
  end

  @impl true
  def handle_playing(_ctx, state) do
    stream_format =
      case state.mode do
        :bytestream ->
          %Membrane.RemoteStream{type: :bytestream}

        :nalu_aligned ->
          %Membrane.H264.RemoteStream{alignment: :nalu, stream_type: state.output_raw_stream_type}

        :au_aligned ->
          %Membrane.H264.RemoteStream{alignment: :au, stream_type: state.output_raw_stream_type}
      end

    {[stream_format: {:output, stream_format}], state}
  end
end
