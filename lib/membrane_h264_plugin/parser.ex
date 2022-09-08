defmodule Membrane.H264.Parser do
  @moduledoc """
  Membrane element providing parser for H264 encoded video stream.

  This parser splits the stream into h264 access units,
  each of which is a sequence of NAL units corresponding to one
  video frame. See `alignment` option. The other alignments are not supported
  at the moment.

  The parser parses caps from the SPS. Because caps must be sent before
  the first buffers, parser drops the stream until the first SPS is received
  by default. See `skip_until_parameters?` option.
  """

  use Membrane.Filter

  require Membrane.Logger

  alias Membrane.{Buffer, H264}
  alias Membrane.H264.Parser.AccessUnitSplitter
  alias Membrane.H264.Parser.{Caps, NALuSplitter, NALuTypes, SchemeParser}
  alias Membrane.H264.Parser.SchemeParser.Schemes

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
      caps: nil,
      metadata: %{},
      unparsed_payload: <<>>,
      splitter_nalus_buffer: [],
      splitter_state: :first,
      previous_primary_coded_picture_nalu: nil,
      scheme_parser_state: %SchemeParser.State{__global__: %{}, __local__: %{}},
      pps: opts.pps,
      sps: opts.sps,
      skip: opts.skip_until_parameters?,
      timestamps_mapping: []
    }

    {:ok, state}
  end

  @impl true
  def handle_caps(:input, _caps, _ctx, state) do
    {:ok, state}
  end

  @impl true
  def handle_process(:input, %Membrane.Buffer{} = buffer, _ctx, state) do
    pts = Map.get(buffer, :pts)
    dts = Map.get(buffer, :dts)

    state = %{
      state
      | timestamps_mapping:
          state.timestamps_mapping ++ [{bit_size(state.unparsed_payload), {pts, dts}}]
    }

    {{:ok, actions}, state} = process(state.unparsed_payload <> buffer.payload, state)
    actions_size = bit_size(get_payload_from_actions(actions))

    timestamps_mapping =
      state.timestamps_mapping
      |> Enum.map(fn {index, {pts, dts}} -> {index - actions_size, {pts, dts}} end)
      |> Enum.filter(fn {index, {_pts, _dts}} -> index >= 0 end)

    state = %{state | timestamps_mapping: timestamps_mapping}
    {{:ok, actions}, state}
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, %{unparsed_payload: payload} = state) do
    {{:ok, actions}, state} = process(payload, state)
    actions_payload = get_payload_from_actions(actions)

    actions_size = byte_size(actions_payload)

    rest_buffer =
      payload
      |> :binary.part(actions_size, byte_size(payload) - actions_size)
      |> then(fn payload ->
        metadata = prepare_metadata(state.splitter_nalus_buffer)
        {pts, dts} = prepare_timestamp(state.timestamps_mapping, actions_size)
        %Buffer{payload: payload, metadata: metadata, pts: pts, dts: dts}
      end)

    {{:ok, actions ++ [buffer: {:output, rest_buffer}, end_of_stream: :output]}, state}
  end

  defp process(payload, state) do
    {nalus, scheme_parser_state} = parse(payload, state.scheme_parser_state)

    {_rest_of_nalus, splitter_nalus_buffer, splitter_state, previous_primary_coded_picture_nalu,
     access_units} = AccessUnitSplitter.split_nalus_into_access_units(nalus)

    unparsed_payload =
      splitter_nalus_buffer
      |> then(&parsed_poslen/1)
      |> then(fn {start, len} -> :binary.part(payload, start, len) end)

    state = %{
      state
      | splitter_nalus_buffer: splitter_nalus_buffer,
        scheme_parser_state: scheme_parser_state,
        splitter_state: splitter_state,
        previous_primary_coded_picture_nalu: previous_primary_coded_picture_nalu,
        unparsed_payload: unparsed_payload
    }

    {new_actions, state} = prepare_actions_for_aus(access_units, payload, state)
    {{:ok, new_actions}, state}
  end

  defp parsed_poslen([]), do: {0, 0}

  defp parsed_poslen(parsed) do
    {start, _len} =
      parsed
      |> hd()
      |> get_in([:prefixed_poslen])

    len =
      parsed
      |> List.last()
      |> get_in([:unprefixed_poslen])
      |> then(fn {last_start, last_len} -> last_start + last_len - start end)

    {start, len}
  end

  defp get_payload_from_actions(actions) do
    actions
    |> Enum.filter(fn {action, _rest} -> action == :buffer end)
    |> Enum.reduce(<<>>, &concatenate_payload_from_buffers_action(&1, &2))
  end

  defp concatenate_payload_from_buffers_action({:buffer, {_pad, buf}}, acc) do
    case buf do
      %Buffer{payload: payload} ->
        acc <> payload

      list_of_buffers ->
        acc <>
          (list_of_buffers |> Enum.map_join(& &1.payload))
    end
  end

  defp prepare_actions_for_aus(aus, payload, acc \\ [], state)

  defp prepare_actions_for_aus([], _payload, acc, state) do
    {acc, state}
  end

  defp prepare_actions_for_aus(aus, payload, acc, state) do
    index = Enum.find_index(aus, &au_with_nalu_of_type?(&1, :sps))

    if index == nil do
      {actions, state} = prepare_actions_without_sps(aus, payload, state)
      {acc ++ actions, state}
    else
      {aus_before_sps, aus_with_sps} = Enum.split(aus, index)
      {no_sps_actions, state} = prepare_actions_without_sps(aus_before_sps, payload, state)
      {sps_actions, state} = prepare_actions_with_sps(aus_with_sps, payload, state)

      prepare_actions_for_aus(
        tl(aus_with_sps),
        payload,
        acc ++ no_sps_actions ++ sps_actions,
        state
      )
    end
  end

  defp au_with_nalu_of_type?(au, type) do
    au
    |> get_in([Access.all(), :type])
    |> Enum.any?(&(&1 == type))
  end

  defp aus_into_buffer_action(aus, payload, state) do
    aus
    |> Enum.map(&wrap_into_buffer(&1, payload, state))
    |> then(&{:buffer, {:output, &1}})
  end

  defp prepare_actions_without_sps([], _payload, state) do
    {[], state}
  end

  defp prepare_actions_without_sps(aus, payload, %{caps: caps, skip: skip} = state) do
    case {caps, skip} do
      {nil, false} ->
        {options_caps, state} = get_caps_from_options(state)
        caps_action = {:caps, {:output, options_caps}}
        buffers_actions = aus_into_buffer_action(aus, payload, state)
        {[caps_action, buffers_actions], %{state | caps: options_caps}}

      {nil, true} ->
        {[], state}

      {_caps, _skip} ->
        {[aus_into_buffer_action(aus, payload, state)], state}
    end
  end

  defp prepare_actions_with_sps(aus_with_sps, payload, state) do
    sps_nalu = aus_with_sps |> hd() |> Enum.find(&(&1.type == :sps))

    sps_payload =
      sps_nalu
      |> then(& &1.prefixed_poslen)
      |> then(fn {start, len} -> :binary.part(payload, start, len) end)

    caps = Caps.from_caps(sps_nalu)
    buffer = wrap_into_buffer(hd(aus_with_sps), payload, state)

    actions = [
      caps: {:output, caps},
      buffer: {:output, buffer}
    ]

    new_state = %{state | caps: caps, sps: sps_payload}

    {actions, new_state}
  end

  defp wrap_into_buffer(access_unit, payload, state) do
    metadata = prepare_metadata(access_unit)

    buffer =
      access_unit
      |> then(&parsed_poslen/1)
      |> then(fn {start, len} ->
        {pts, dts} = prepare_timestamp(state.timestamps_mapping, start)
        {:binary.part(payload, start, len), pts, dts}
      end)
      |> then(fn {payload, pts, dts} ->
        %Buffer{payload: payload, metadata: metadata, pts: pts, dts: dts}
      end)

    buffer
  end

  defp prepare_timestamp(timestamps_mapping, start_pos) do
    result =
      timestamps_mapping
      |> Enum.find(fn
        {index, {_pts, _dts}} -> index >= start_pos
        _else -> false
      end)

    case result do
      {_index, {pts, dts}} -> {pts, dts}
      _else -> {nil, nil}
    end
  end

  defp prepare_metadata(nalus) do
    is_keyframe = Enum.any?(nalus, fn nalu -> nalu.type == :idr end)
    nalu_start = 0

    nalus =
      nalus
      |> Enum.zip(0..(length(nalus) - 1))
      |> Enum.map_reduce(nalu_start, fn {nalu, i}, nalu_start ->
        unprefixed_start_offset =
          (nalu.unprefixed_poslen |> elem(0)) - (nalu.prefixed_poslen |> elem(0))

        metadata = %{
          metadata: %{
            h264: %{
              type: nalu.type
            }
          },
          prefixed_poslen: {nalu_start, nalu.prefixed_poslen |> elem(1)},
          unprefixed_poslen:
            {unprefixed_start_offset + nalu_start, nalu.unprefixed_poslen |> elem(1)}
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

        {metadata, nalu_start + (nalu.prefixed_poslen |> elem(1))}
      end)
      |> elem(0)

    %{h264: %{key_frame?: is_keyframe, nalus: nalus}}
  end

  defp get_caps_from_options(%{sps: <<>>} = state) do
    {Caps.default_caps(), state}
  end

  defp get_caps_from_options(%{sps: sps, scheme_parser_state: scheme_parser_state} = state) do
    {[sps | _rest], new_scheme_parser_state} = parse(sps, scheme_parser_state)
    {Caps.from_caps(sps), %{state | scheme_parser_state: new_scheme_parser_state}}
  end

  defp parse(payload, state) do
    {nalus, state} =
      payload
      |> NALuSplitter.extract_nalus()
      |> Enum.map_reduce(state, fn nalu, state ->
        {nalu_start_in_bytes, _nalu_size_in_bytes} = nalu.unprefixed_poslen
        nalu_start = nalu_start_in_bytes * 8

        <<_beggining::size(nalu_start), header_bits::binary-size(1), _rest::bitstring>> = payload

        {_rest_of_nalu_payload, state} =
          SchemeParser.parse_with_scheme(header_bits, Schemes.NALuHeader.scheme(), state)

        new_state = %SchemeParser.State{__global__: state.__global__, __local__: %{}}
        {Map.put(nalu, :parsed_fields, state.__local__), new_state}
      end)

    nalus =
      nalus
      |> Enum.map(fn nalu ->
        Map.put(nalu, :type, NALuTypes.get_type(nalu.parsed_fields.nal_unit_type))
      end)

    {nalus, state} =
      nalus
      |> Enum.map_reduce(state, fn nalu, state ->
        {nalu_start_in_bytes, nalu_size_in_bytes} = nalu.unprefixed_poslen
        nalu_start = nalu_start_in_bytes * 8
        nalu_without_header_size_in_bytes = nalu_size_in_bytes - 1

        <<_beggining::size(nalu_start), _header_bits::8,
          nalu_body_payload::binary-size(nalu_without_header_size_in_bytes),
          _rest::bitstring>> = payload

        state = Map.put(state, :__local__, nalu.parsed_fields)

        {_rest_of_nalu_payload, state} = parse_proper_nalu_type(nalu_body_payload, state)

        new_state = %SchemeParser.State{__global__: state.__global__, __local__: %{}}
        {Map.put(nalu, :parsed_fields, state.__local__), new_state}
      end)

    {nalus, state}
  end

  defp parse_proper_nalu_type(payload, state) do
    case NALuTypes.get_type(state.__local__.nal_unit_type) do
      :sps ->
        SchemeParser.parse_with_scheme(payload, Schemes.SPS.scheme(), state)

      :pps ->
        SchemeParser.parse_with_scheme(payload, Schemes.PPS.scheme(), state)

      :idr ->
        SchemeParser.parse_with_scheme(payload, Schemes.Slice.scheme(), state)

      :non_idr ->
        SchemeParser.parse_with_scheme(payload, Schemes.Slice.scheme(), state)

      _unknown_nalu_type ->
        {payload, state}
    end
  end
end
