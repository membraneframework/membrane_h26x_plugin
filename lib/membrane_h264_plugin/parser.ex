defmodule Membrane.H264.Parser do
  @moduledoc false

  use Membrane.Filter

  require Membrane.Logger

  alias Membrane.{Buffer, H264}
  alias Membrane.H264.AccessUnitSplitter
  alias Membrane.H264.Parser.{Caps, NALu, State}

  def_input_pad :input,
    demand_unit: :buffers,
    demand_mode: :auto,
    caps: :any

  def_output_pad :output,
    demand_mode: :auto,
    caps: {H264, stream_format: :byte_stream}

  def_options alignment: [
                type: :atom,
                spec: :au | :nal,
                default: :au,
                description: """
                Stream units carried by each output buffer. See `t:Membrane.H264.alignment_t`.

                Only `:au` alignment is supported at the moment.
                """
              ],
              sps: [
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
                """
              ]

  @impl true
  def handle_init(opts) do
    if opts.alignment != :au do
      raise("Invalid element options, only `:au` alignment is available")
    end

    state = %{
      caps: nil,
      metadata: %{},
      unparsed_payload: <<>>,
      splitter_nalus_buffer: [],
      splitter_state: :first,
      previous_primary_coded_picture_nalu: nil,
      parser_state: %State{__global__: %{}, __local__: %{}},
      sps: opts.sps,
      skip: opts.skip_until_parameters?,
      pts: nil,
      dts: nil,
      prev_pts: nil,
      prev_dts: nil,
      unparsed_size: 0
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
    state = %{state | pts: pts, dts: dts}
    {{:ok, actions}, state} = process(state.unparsed_payload <> buffer.payload, state)

    state = %{
      state
      | prev_pts: pts,
        prev_dts: dts,
        unparsed_size: bit_size(state.unparsed_payload)
    }

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
        %Buffer{payload: payload, metadata: metadata, pts: state.pts, dts: state.dts}
      end)

    {{:ok, actions ++ [buffer: {:output, rest_buffer}, end_of_stream: :output]}, state}
  end

  defp process(payload, state) do
    {nalus, parser_state} = NALu.parse(payload, state.parser_state)

    {_rest_of_nalus, splitter_nalus_buffer, splitter_state, previous_primary_coded_picture_nalu,
     access_units} = AccessUnitSplitter.split_nalus_into_access_units(nalus)

    unparsed_payload =
      splitter_nalus_buffer
      |> then(&parsed_poslen/1)
      |> then(fn {start, len} -> :binary.part(payload, start, len) end)

    state = %{
      state
      | splitter_nalus_buffer: splitter_nalus_buffer,
        parser_state: parser_state,
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
    |> Enum.reduce(<<>>, fn {:buffer, {_pad, %Buffer{payload: payload}}}, acc ->
      acc <> payload
    end)
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
    # TODO: don't pass hardcoded empty metadata
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

    caps = Caps.parse_caps(sps_nalu)

    actions = [
      caps: {:output, caps},
      buffer: {:output, wrap_into_buffer(hd(aus_with_sps), payload, state)}
    ]

    new_state = %{state | caps: caps, sps: sps_payload}

    {actions, new_state}
  end

  defp wrap_into_buffer(access_unit, payload, state) do
    metadata = prepare_metadata(access_unit)

    access_unit
    |> then(&parsed_poslen/1)
    |> then(fn {start, len} ->
      pts = if start < state.unparsed_size, do: state.prev_pts, else: state.pts
      dts = if start < state.unparsed_size, do: state.prev_dts, else: state.dts
      {:binary.part(payload, start, len), pts, dts}
    end)
    |> then(fn {payload, pts, dts} ->
      %Buffer{payload: payload, metadata: metadata, pts: pts, dts: dts}
    end)
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

  defp get_caps_from_options(%{sps: sps, parser_state: parser_state} = state) do
    {[sps | _rest], new_parser_state} = NALu.parse(sps, parser_state)
    {Caps.parse_caps(sps), %{state | parser_state: new_parser_state}}
  end
end
