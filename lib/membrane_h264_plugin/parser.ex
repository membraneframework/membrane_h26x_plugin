defmodule Membrane.H264.Parser do
  @moduledoc false

  use Membrane.Filter

  require Membrane.Logger

  alias __MODULE__
  alias Membrane.{Buffer, H264}
  alias Membrane.H264.AccessUnitSplitter

  @default_caps %H264{
    alignment: :au,
    framerate: {30, 1},
    height: 720,
    nalu_in_metadata?: false,
    profile: :high,
    stream_format: :byte_stream,
    width: 1280
  }

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
      splitter_buffer: [],
      splitter_state: :first,
      previous_primary_coded_picture_nalu: nil,
      parser_state: %Membrane.H264.Parser.State{__global__: %{}, __local__: %{}},
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
    process(state.unparsed_payload <> buffer.payload, [], state)
  end

  @impl true

  def handle_end_of_stream(:input, _ctx, %{unparsed_payload: payload} = state) do
    # process(payload, [end_of_stream: :output], state)
    {{:ok, buffer: {:output, %Buffer{payload: payload}}, end_of_stream: :output}, state}
  end

  defp process(payload, actions, state) do
    {nalus, parser_state} = Parser.NALu.parse(payload, state.parser_state)

    {_rest_of_nalus, splitter_buffer, splitter_state, previous_primary_coded_picture_nalu,
     access_units} = AccessUnitSplitter.split_nalus_into_access_units(nalus)

    unparsed_payload =
      splitter_buffer
      |> then(&parsed_poslen/1)
      |> then(fn {start, len} -> :binary.part(payload, start, len) end)

    state = %{
      state
      | splitter_buffer: splitter_buffer,
        parser_state: parser_state,
        splitter_state: splitter_state,
        previous_primary_coded_picture_nalu: previous_primary_coded_picture_nalu,
        unparsed_payload: unparsed_payload
    }

    {new_actions, state} = aus_into_actions(access_units, payload, state)
    {{:ok, new_actions ++ actions}, state}
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

  defp aus_into_actions(aus, payload, acc \\ [], state)

  defp aus_into_actions(aus, payload, acc, %{caps: caps} = state) do
    index = Enum.find_index(aus, &au_with_nalu_of_type?(&1, :sps))

    if index == nil do
      {actions, state} = no_sps_actions(aus, payload, state)
      {acc ++ actions, state}
    else
      {aus_before_sps, aus_with_sps} = Enum.split(aus, index)
      {no_sps_actions, state} = no_sps_actions(aus_before_sps, payload, state)

      sps_map = aus_with_sps |> hd() |> Enum.find(&(&1.type == :sps))

      sps_payload =
        sps_map
        |> then(& &1.prefixed_poslen)
        |> then(fn {start, len} -> :binary.part(payload, start, len) end)

      caps = get_caps(sps_map)

      actions = [
        caps: {:output, caps},
        buffer: {:output, wrap_into_buffer(hd(aus_with_sps), payload, state)}
      ]

      new_state = %{state | caps: caps, sps: sps_payload}

      aus_into_actions(tl(aus_with_sps), acc ++ no_sps_actions ++ actions, new_state)
    end
  end

  defp aus_into_actions([], _payload, acc, state) do
    {acc, state}
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

  defp no_sps_actions([], _payload, state) do
    {[], state}
  end

  defp no_sps_actions(aus, payload, %{caps: caps, skip: skip} = state) do
    case {caps, skip} do
      {nil, false} ->
        {options_caps, state} = get_options_caps(state)
        caps_action = {:caps, {:output, options_caps}}
        buffers_actions = aus_into_buffer_action(aus, payload, state)
        {[caps_action, buffers_actions], %{state | caps: options_caps}}

      {nil, true} ->
        {[], state}

      {caps, _skip} ->
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

  defp get_caps(sps_nal) do
    sps = sps_nal.parsed_fields

    width_in_mbs = sps.pic_width_in_mbs_minus1 + 1
    width = width_in_mbs * 16

    height_in_map_units = sps.pic_width_in_mbs_minus1 + 1
    height_in_mbs = (2 - sps.frame_mbs_only_flag) * height_in_map_units
    height = height_in_mbs * 16

    %H264{@default_caps | width: width, height: height}
  end

  defp get_options_caps(%{sps: <<>>} = state) do
    {@default_caps, state}
  end

  defp get_options_caps(%{sps: sps, parser_state: parser_state} = state) do
    {[sps | _rest], new_parser_state} = NALu.parse(sps, parser_state)
    {get_caps(sps), %{state | parser_state: new_parser_state}}
  end
end
