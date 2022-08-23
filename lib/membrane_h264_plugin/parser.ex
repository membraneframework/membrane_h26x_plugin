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
      skip: opts.skip_until_parameters?
    }

    {:ok, state}
  end

  @impl true
  def handle_caps(:input, _caps, _ctx, state) do
    {:ok, state}
  end

  @impl true
  def handle_process(:input, %Membrane.Buffer{} = buffer, _ctx, state) do
    process(state.unparsed_payload <> buffer.payload, state)
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
      %Buffer{payload: payload, metadata: state.metadata}
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
    |> Enum.filter(fn {action, rest} -> action == :buffer end)
    |> Enum.reduce(<<>>, fn {:buffer, {_pad, %Buffer{payload: payload}}}, acc -> acc <> payload end)
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

      sps_map = aus_with_sps |> hd() |> Enum.find(&(&1.type == :sps))

      sps_payload =
        sps_map
        |> then(& &1.prefixed_poslen)
        |> then(fn {start, len} -> :binary.part(payload, start, len) end)

      caps = Caps.parse_caps(sps_map)

      actions = [
        caps: {:output, caps},
        buffer: {:output, wrap_into_buffer(hd(aus_with_sps), payload, state)}
      ]

      new_state = %{state | caps: caps, sps: sps_payload}

      prepare_actions_for_aus(
        tl(aus_with_sps),
        payload,
        acc ++ no_sps_actions ++ actions,
        new_state
      )
    end
  end

  defp au_with_nalu_of_type?(au, type) do
    au
    |> get_in([Access.all(), :type])
    |> Enum.any?(&(&1 == type))
  end

  defp aus_into_buffer_action(aus, payload, %{metadata: metadata}) do
    aus
    # FIXME: don't pass hardcoded empty metadata
    |> Enum.map(&wrap_into_buffer(&1, payload, metadata))
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

  defp wrap_into_buffer(access_unit, payload, metadata) do
    access_unit
    |> then(&parsed_poslen/1)
    |> then(fn {start, len} -> :binary.part(payload, start, len) end)
    |> then(fn payload ->
      %Buffer{payload: payload, metadata: metadata}
    end)
  end

  defp get_caps_from_options(%{sps: <<>>} = state) do
    {Caps.default_caps(), state}
  end

  defp get_caps_from_options(%{sps: sps, parser_state: parser_state} = state) do
    {[sps | _rest], new_parser_state} = NALu.parse(sps, parser_state)
    {Caps.parse_caps(sps), %{state | parser_state: new_parser_state}}
  end
end
