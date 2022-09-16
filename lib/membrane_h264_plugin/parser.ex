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
  alias Membrane.H264.Parser.AccessUnitSplitter
  alias Membrane.H264.Parser.{Caps, NALu, NALuSplitter, NALuTypes, SchemeParser}
  alias Membrane.H264.Parser.SchemeParser.Schemes
  alias Membrane.RemoteStream

  def_input_pad :input,
    demand_unit: :buffers,
    demand_mode: :auto,
    caps: RemoteStream

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
      caps: nil,
      metadata: %{},
      splitter_nalus_acc: [],
      splitter_state: :first,
      previous_primary_coded_picture_nalu: nil,
      scheme_parser_state: %SchemeParser.State{__global__: %{}, __local__: %{}},
      pps: opts.pps,
      sps: opts.sps,
      should_skip_bufffers?: true,
      timestamps_mapping: [],
      unparsed_payload: opts.sps <> opts.pps,
      last_pts: nil,
      last_dts: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_caps(:input, _caps, _ctx, state) do
    {:ok, state}
  end

  @impl true
  def handle_process(:input, %Membrane.Buffer{} = buffer, _ctx, state) do
    payload = state.unparsed_payload <> buffer.payload

    {nalus, scheme_parser_state} =
      parse(
        payload,
        state.scheme_parser_state,
        buffer.pts,
        buffer.dts,
        state.last_pts,
        state.last_dts
      )

    unparsed_payload_start =
      nalus |> Enum.reduce(0, fn nalu, acc -> acc + byte_size(nalu.payload) end)

    unparsed_payload =
      :binary.part(payload, unparsed_payload_start, byte_size(payload) - unparsed_payload_start)

    {[], splitter_nalus_acc, splitter_state, previous_primary_coded_picture_nalu, access_units} =
      AccessUnitSplitter.split_nalus_into_access_units(
        nalus,
        state.splitter_nalus_acc,
        state.splitter_state,
        state.previous_primary_coded_picture_nalu
      )

    state = %{
      state
      | splitter_nalus_acc: splitter_nalus_acc,
        scheme_parser_state: scheme_parser_state,
        splitter_state: splitter_state,
        previous_primary_coded_picture_nalu: previous_primary_coded_picture_nalu,
        unparsed_payload: unparsed_payload,
        last_pts: buffer.pts,
        last_dts: buffer.dts
    }

    actions = prepare_actions_for_aus(access_units)
    {{:ok, actions}, state}
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, state) do
    {nalus, _scheme_parser_state} =
      parse(
        state.unparsed_payload,
        state.scheme_parser_state,
        nil,
        nil,
        state.last_pts,
        state.last_dts,
        false
      )

    {[], splitter_nalus_acc, _splitter_state, _previous_primary_coded_picture_nalu, access_units} =
      AccessUnitSplitter.split_nalus_into_access_units(
        nalus,
        state.splitter_nalus_acc,
        state.splitter_state,
        state.previous_primary_coded_picture_nalu
      )

    actions = prepare_actions_for_aus(access_units)

    sent_remaining_buffers_actions =
      if splitter_nalus_acc != [] do
        rest_buffer = wrap_into_buffer(splitter_nalus_acc)
        [buffer: {:output, rest_buffer}]
      else
        []
      end

    {{:ok, actions ++ sent_remaining_buffers_actions ++ [end_of_stream: :output]}, state}
  end

  defp prepare_actions_for_aus(aus) do
    Enum.reduce(aus, [], fn au, acc ->
      sps_actions =
        if au_with_nalu_of_type?(au, :sps) do
          sps_nalu = au |> Enum.find(&(&1.type == :sps))
          caps = Caps.from_caps(sps_nalu)
          [caps: {:output, caps}]
        else
          []
        end

      acc ++ sps_actions ++ au_into_buffer_action(au)
    end)
  end

  defp au_with_nalu_of_type?(au, type) do
    au
    |> get_in([Access.all(), :type])
    |> Enum.any?(&(&1 == type))
  end

  defp au_into_buffer_action(au) do
    [{:buffer, {:output, wrap_into_buffer(au)}}]
  end

  defp wrap_into_buffer(access_unit) do
    metadata = prepare_metadata(access_unit)
    pts = access_unit |> Enum.at(0) |> then(& &1.pts)
    dts = access_unit |> Enum.at(0) |> then(& &1.dts)

    buffer =
      access_unit
      |> Enum.reduce(<<>>, fn nalu, acc ->
        acc <> nalu.payload
      end)
      |> then(fn payload ->
        %Buffer{payload: payload, metadata: metadata, pts: pts, dts: dts}
      end)

    buffer
  end

  defp prepare_metadata(nalus) do
    is_keyframe = Enum.any?(nalus, fn nalu -> nalu.type == :idr end)

    nalus =
      nalus
      |> Enum.zip(0..(length(nalus) - 1))
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

  defp parse(payload, state, pts, dts, last_pts, last_dts, should_skip_last_nalu? \\ true) do
    {nalus, state} =
      payload
      |> NALuSplitter.extract_nalus(
        pts,
        dts,
        last_pts,
        last_dts,
        should_skip_last_nalu?
      )
      |> Enum.map_reduce(state, fn nalu, state ->
        prefix_length = nalu.prefix_length

        <<_prefix::binary-size(prefix_length), nalu_header::binary-size(1), nalu_body::binary>> =
          nalu.payload

        new_state = SchemeParser.State.new(state)

        {parsed_fields, state} =
          SchemeParser.parse_with_scheme(nalu_header, Schemes.NALuHeader.scheme(), new_state)

        type = NALuTypes.get_type(parsed_fields.nal_unit_type)
        {parsed_fields, state} = parse_proper_nalu_type(nalu_body, state, type)

        {%NALu{nalu | parsed_fields: parsed_fields, type: type}, state}
      end)

    {nalus, state}
  end

  defp parse_proper_nalu_type(payload, state, type) do
    case type do
      :sps ->
        SchemeParser.parse_with_scheme(payload, Schemes.SPS.scheme(), state)

      :pps ->
        SchemeParser.parse_with_scheme(payload, Schemes.PPS.scheme(), state)

      :idr ->
        SchemeParser.parse_with_scheme(payload, Schemes.Slice.scheme(), state)

      :non_idr ->
        SchemeParser.parse_with_scheme(payload, Schemes.Slice.scheme(), state)

      _unknown_nalu_type ->
        {%{}, state}
    end
  end
end
