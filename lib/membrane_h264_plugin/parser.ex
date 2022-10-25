defmodule Membrane.H264.Parser do
  @moduledoc """
  Membrane element providing parser for H264 encoded video stream.

  The parser parses caps from the SPS. Because caps must be sent before
  the first buffers, parser drops the stream until the first SPS is received
  by default. See `skip_until_parameters?` option.
  """

  use Membrane.Filter

  require Membrane.Logger

  alias Membrane.{Buffer, H264}
  alias Membrane.H264.Parser.{AUSplitter, Caps, NALuParser, NALuSplitter}

  def_input_pad :input,
    demand_unit: :buffers,
    demand_mode: :auto,
    caps: :any

  def_output_pad :output,
    demand_mode: :auto,
    caps: {H264, stream_format: :byte_stream}

  def_options sps: [
                type: :binary,
                default: <<>>,
                description: """
                Sequence Parameter Set NAL unit - if absent in the stream, should
                be provided via this option.
                """
              ],
              pps: [
                type: :binary,
                default: <<>>,
                description: """
                Picture Parameter Set NAL unit - if absent in the stream, should
                be provided via this option.
                """
              ],
              skip_until_parameters?: [
                type: :boolean,
                default: true,
                description: """
                Determines whether to drop the stream until the first set of SPS and PPS is received.

                If this option is set to `false` and no SPS is provided by the
                `sps` option, the parser will send default 30fps, 720p caps
                as first caps.
                """
              ]

  @impl true
  def handle_init(opts) do
    state = %{
      params: opts.sps <> opts.pps,
      nalu_splitter: NALuSplitter.new(),
      nalu_parser: NALuParser.new(),
      au_splitter: AUSplitter.new()
    }

    {:ok, state}
  end

  @impl true
  def handle_caps(:input, _caps, _ctx, state) do
    {:ok, state}
  end

  @impl true
  def handle_process(:input, %Membrane.Buffer{} = buffer, _ctx, state) do
    payload = state.params <> buffer.payload
    {nalus_payloads_list, nalu_splitter} = NALuSplitter.split(payload, state.nalu_splitter)

    {nalus, nalu_parser} =
      Enum.map_reduce(nalus_payloads_list, state.nalu_parser, fn nalu_payload, nalu_parser ->
        NALuParser.parse(nalu_payload, nalu_parser)
      end)

    {access_units, au_splitter} =
      nalus
      |> Enum.filter(fn nalu -> nalu.status == :valid end)
      |> AUSplitter.split_nalus(state.au_splitter)

    actions = prepare_actions_for_aus(access_units)

    state = %{
      state
      | nalu_splitter: nalu_splitter,
        nalu_parser: nalu_parser,
        au_splitter: au_splitter,
        params: <<>>
    }

    {{:ok, actions}, state}
  end

  @impl true
  def handle_end_of_stream(:input, ctx, state) do
    {last_nalu_payload, nalu_splitter} = NALuSplitter.flush(state.nalu_splitter)
    {last_nalu, nalu_parser} = NALuParser.parse(last_nalu_payload, state.nalu_parser)

    {access_units, au_splitter} =
      if last_nalu.status == :valid do
        AUSplitter.split_nalus([last_nalu], state.au_splitter)
      else
        {[], state.au_splitter}
      end

    {remaining_nalus, au_splitter} = AUSplitter.flush(au_splitter)
    maybe_improper_aus = access_units ++ [remaining_nalus]
    actions = prepare_actions_for_aus(maybe_improper_aus)
    actions = if caps_sent?(actions, ctx), do: actions, else: []

    state = %{
      state
      | nalu_splitter: nalu_splitter,
        nalu_parser: nalu_parser,
        au_splitter: au_splitter
    }

    {{:ok, actions ++ [end_of_stream: :output]}, state}
  end

  defp prepare_actions_for_aus(aus) do
    Enum.reduce(aus, [], fn au, acc ->
      sps_actions =
        case Enum.find(au, &(&1.type == :sps)) do
          nil -> []
          sps_nalu -> [caps: {:output, Caps.from_sps(sps_nalu)}]
        end

      acc ++ sps_actions ++ [{:buffer, {:output, wrap_into_buffer(au)}}]
    end)
  end

  defp wrap_into_buffer(access_unit) do
    metadata = prepare_metadata(access_unit)

    buffer =
      access_unit
      |> Enum.reduce(<<>>, fn nalu, acc ->
        acc <> nalu.payload
      end)
      |> then(fn payload ->
        %Buffer{payload: payload, metadata: metadata}
      end)

    buffer
  end

  defp prepare_metadata(nalus) do
    is_keyframe = Enum.any?(nalus, fn nalu -> nalu.type == :idr end)

    nalus =
      nalus
      |> Enum.with_index()
      |> Enum.map_reduce(0, fn {nalu, i}, nalu_start ->
        metadata = %{
          metadata: %{
            h264: %{
              type: nalu.type
            }
          },
          prefixed_poslen: {nalu_start, byte_size(nalu.payload)},
          unprefixed_poslen:
            {nalu_start + nalu.prefix_length, byte_size(nalu.payload) - nalu.prefix_length}
        }

        metadata =
          if i == length(nalus) - 1 do
            put_in(metadata, [:metadata, :h264, :end_access_unit], true)
          else
            metadata
          end

        metadata =
          if i == 0 do
            put_in(metadata, [:metadata, :h264, :new_access_unit], %{key_frame?: is_keyframe})
          else
            metadata
          end

        {metadata, nalu_start + byte_size(nalu.payload)}
      end)
      |> elem(0)

    %{h264: %{key_frame?: is_keyframe, nalus: nalus}}
  end

  defp caps_sent?(actions, %{pads: %{output: %{caps: nil}}}),
    do: Enum.any?(actions, &match?({:caps, _caps}, &1))

  defp caps_sent?(_actions, _ctx), do: true
end
