defmodule Membrane.H264.Parser do
  @moduledoc """
  Membrane element providing parser for H264 encoded video stream.

  The parser:
  * prepares and sends the appropriate stream format, based on information provided in the stream and via the element's options
  * splits the incoming stream into H264 access units - each buffer being output is a `Membrane.Buffer` struct with a
  binary payload of a single access unit or network abstraction layer unit.
  * enriches the output buffers with the metadata describing the way the access unit is split into NAL units, type of each NAL unit
  making up the access unit and the information if the access unit hold a keyframe.
  * converts the stream's structure (Annex B, avc1 or avc3) to the one provided via the element's options.

  The parser works in one of three possible modes, depending on the structure of the input buffers:
  * `:bytestream` - each input buffer contains some part of H264 stream's payload, but not necessary a logical
  H264 unit (like NAL unit or an access unit). Can be used for i.e. for parsing the stream read from the file.
  * `:nalu_aligned` - each input buffer contains a single NAL unit's payload
  * `:au_aligned` - each input buffer contains a single access unit's payload

  The parser's mode is set automatically, based on the input stream format received by that element:
  * Receiving `Membrane.RemoteStream` results in the parser mode being set to `:bytestream`
  * Receiving `%Membrane.H264{alignment: :nalu}` results in the parser mode being set to `:nalu_aligned`
  * Receiving `%Membrane.H264{alignment: :au}` results in the parser mode being set to `:au_aligned`

  The distinction between parser modes was introduced to eliminate the redundant operations and to provide a reliable way
  for rewriting of timestamps:
  * in the `:bytestream` mode:
    * if option `:framerate` is set to nil, the output buffers have their `:pts` and `:dts` set to nil
    * if framerate is specified, `:pts` and `:dts` will be generated automatically, based on that framerate, starting from 0
     This may only be used with H264 profiles `:baseline` and `:constrained_baseline`, where `PTS==DTS`.
  * in the `:nalu_aligned` mode, the output buffers have their `:pts` and `:dts` set to `:pts` and `:dts` of the
   input buffer that was holding the first NAL unit making up given access unit (that is being sent inside that output buffer).
  * in the `:au_aligned` mode, the output buffers have their `:pts` and `:dts` set to `:pts` and `:dts` of the input buffer
  (holding the whole access unit being output)

  The parser also allows for conversion between stream structures. The available structures are:
  * Annex B, `:annexb` - In a stream with this structure each NAL unit is prefixed by three or
  four-byte start code (`0x(00)000001`) that allows to identify boundaries between them.
  * avc1, `:avc1` - In such stream a DCR (Decoder Configuration Record) is included in `stream_format`
  and NALUs lack the start codes, but are prefixed with their length. The length of these prefixes
  is contained in the stream's DCR. PPSs and SPSs (Picture Parameter Sets and Sequence Parameter Sets) are
  transported in the DCR.
  * avc3, `:avc3` - The same as avc1, only that parameter sets may be also present in the stream
  (in-band).
  """

  use Membrane.Filter

  require Membrane.Logger

  alias Membrane.{H264, RemoteStream}
  alias Membrane.H264.{AUSplitter, AUTimestampGenerator, DecoderConfigurationRecord, NALuParser}
  alias Membrane.H26x.Parser.{Core, Utils}

  @nalu_length_size 4
  @metadata_key :h264

  def_input_pad :input,
    flow_control: :auto,
    accepted_format: any_of(RemoteStream, H264)

  def_output_pad :output,
    flow_control: :auto,
    accepted_format:
      %H264{alignment: alignment, nalu_in_metadata?: true} when alignment in [:nalu, :au]

  def_options spss: [
                spec: [binary()],
                default: [],
                description: """
                Sequence Parameter Set NAL unit binary payloads - if absent in the stream, should
                be provided via this option (only available for `:annexb` output stream structure).
                """
              ],
              ppss: [
                spec: [binary()],
                default: [],
                description: """
                Picture Parameter Set NAL unit binary payloads - if absent in the stream, should
                be provided via this option (only available for `:annexb` output stream structure).
                """
              ],
              output_alignment: [
                spec: :au | :nalu,
                default: :au,
                description: """
                Alignment of the buffers produced as an output of the parser.
                If set to `:au`, each output buffer will be a single access unit.
                Otherwise, if set to `:nalu`, each output buffer will be a single NAL unit.
                Defaults to `:au`.
                """
              ],
              skip_until_keyframe: [
                spec: boolean(),
                default: true,
                description: """
                Determines whether to drop the stream until the first key frame is received.
                """
              ],
              repeat_parameter_sets: [
                spec: boolean(),
                default: false,
                description: """
                Repeat all parameter sets (`sps` and `pps`) on each IDR picture.

                Parameter sets may be retrieved from:
                  * The stream
                  * `Parser` options.
                  * Decoder Configuration Record, sent in `:acv1` and `:avc3` stream types
                """
              ],
              output_stream_structure: [
                spec:
                  nil
                  | stream_structure()
                  | :avc1
                  | :avc3,
                default: nil,
                description: """
                format of the outgoing H264 stream, if set to `:annexb` NALUs will be separated by
                a start code (0x(00)000001) or if set to `:avc3` or `:avc1` they will be prefixed by their size.
                Additionally for `:avc1` and `:avc3` a tuple can be passed containing the atom and
                `nalu_length_size` that determines the size in bytes of each NALU's field
                describing their length (by default 4). In avc1 output streams the PPSs and SPSs will be
                transported in the DCR, when in avc3 they will be present only in the stream (in-band).
                If not provided or set to nil the stream's structure will remain unchanged.
                """
              ],
              generate_best_effort_timestamps: [
                spec:
                  false
                  | %{
                      :framerate => {pos_integer(), pos_integer()},
                      optional(:add_dts_offset) => boolean()
                    },
                default: false,
                description: """
                Generates timestamps based on given `framerate`.

                This option works only when `Membrane.RemoteStream` format arrives.

                Keep in mind that the generated timestamps may be inaccurate and lead
                to video getting out of sync with other media, therefore h264 should
                be kept in a container that stores the timestamps alongside.

                PTS are derived from each frame's presentation order, recovered by
                sorting the access units by their Picture Order Count (POC). Because
                PTS are based on the relative POC order rather than the absolute POC
                values, the timestamps are correct regardless of the step by which POC
                advances.

                Recovering the presentation order requires buffering (reordering) a
                bounded number of access units before emitting them, which introduces
                a constant latency of that many frame durations. This only happens when
                the stream can actually reorder frames; when it can't (baseline /
                constrained baseline profile, or `pic_order_cnt_type == 2`) the
                buffering is disabled and no latency is added. When the SPS VUI provides
                `max_num_reorder_frames`, it is used as the exact buffer depth, keeping
                the latency as low as the stream allows; otherwise a safe maximum of 15
                frames (half a second at 30 FPS) is assumed.

                By default, the parser adds negative DTS offset to the timestamps,
                so that in case of frame reorder (which always happens when B frames
                are present) the DTS was always bigger than PTS. If that is not desired,
                you can set `add_dts_offset: false`.
                """
              ]

  @typedoc """
  Format of the H264 stream, if set to `:annexb` NALUs will be separated by
  a start code (0x(00)000001) or if set to `:avc3` or `:avc1` they will
  be prefixed by their size.
  """
  @type stream_structure ::
          :annexb | {codec_tag :: :avc1 | :avc3, nalu_length_size :: pos_integer()}

  @impl true
  def handle_init(_ctx, opts) do
    output_stream_structure =
      case opts.output_stream_structure do
        :avc1 -> {:avc1, @nalu_length_size}
        :avc3 -> {:avc3, @nalu_length_size}
        stream_structure -> stream_structure
      end

    core =
      Core.new(%{
        nalu_parser_mod: NALuParser,
        au_splitter_mod: AUSplitter,
        au_timestamp_generator_mod: AUTimestampGenerator,
        generate_best_effort_timestamps: opts.generate_best_effort_timestamps,
        output_stream_structure: output_stream_structure
      })

    state = %{
      core: core,
      output_alignment: opts.output_alignment,
      skip_until_keyframe: opts.skip_until_keyframe,
      repeat_parameter_sets: opts.repeat_parameter_sets,
      initial_parameter_sets: opts.spss ++ opts.ppss
    }

    {[], state}
  end

  @impl true
  def handle_stream_format(:input, stream_format, ctx, state) do
    {alignment, input_stream_structure, parameter_sets} =
      parse_raw_input_stream_structure(stream_format)

    is_first_received_stream_format = is_nil(ctx.pads.output.stream_format)
    mode = Core.mode_from_alignment(alignment)

    {au_actions, state} =
      cond do
        is_first_received_stream_format ->
          framerate = Map.get(stream_format, :framerate) || Core.framerate(state.core)
          core = Core.init_input_structure(state.core, mode, input_stream_structure, framerate)
          {[], %{state | core: core}}

        not Core.input_stream_structure_change_allowed?(
          input_stream_structure,
          Core.input_stream_structure(state.core)
        ) ->
          raise "stream structure cannot be fundamentally changed during stream"

        mode != Core.mode(state.core) ->
          {actions, state} = flush_and_process(ctx, state)
          {actions, %{state | core: Core.set_mode(state.core, mode)}}

        true ->
          {[], state}
      end

    incoming_parameter_sets =
      incoming_parameter_sets(
        input_stream_structure,
        parameter_sets,
        is_first_received_stream_format,
        state
      )

    {stream_format_actions, state} =
      handle_stream_format_parameter_sets(
        incoming_parameter_sets,
        ctx.pads.output.stream_format,
        state
      )

    {au_actions ++ stream_format_actions, state}
  end

  @impl true
  def handle_buffer(:input, %Membrane.Buffer{} = buffer, ctx, state) do
    {access_units, core} =
      Core.process_buffer(state.core, buffer.payload, {buffer.pts, buffer.dts})

    process_access_units(access_units, ctx, %{state | core: core})
  end

  @impl true
  def handle_end_of_stream(:input, ctx, state)
      when state.core.mode != :au_aligned and ctx.pads.input.start_of_stream? do
    {actions, state} = flush_and_process(ctx, state)
    actions = if Utils.stream_format_sent?(actions, ctx), do: actions, else: []
    {actions ++ [end_of_stream: :output], state}
  end

  @impl true
  def handle_end_of_stream(_pad, _ctx, state) do
    {[end_of_stream: :output], state}
  end

  @spec flush_and_process(map(), map()) :: {[Membrane.Element.Action.t()], map()}
  defp flush_and_process(ctx, state) do
    {access_units, core} = Core.flush(state.core)
    process_access_units(access_units, ctx, %{state | core: core})
  end

  @spec process_access_units([Core.access_unit()], map(), map()) ::
          {[Membrane.Element.Action.t()], map()}
  defp process_access_units(access_units, ctx, state) do
    Enum.flat_map_reduce(access_units, state, fn au, state ->
      {au, stream_format_actions, state} = handle_au_parameter_sets(au, ctx, state)
      {buffer_actions, state} = prepare_buffer_actions(au, keyframe?(au), state)
      {stream_format_actions ++ buffer_actions, state}
    end)
  end

  defp handle_au_parameter_sets(au, ctx, state) do
    parameter_sets = get_parameter_sets(au)

    {stream_format_actions, state} =
      cache_and_maybe_stream_format(parameter_sets, ctx.pads.output.stream_format, state)

    au =
      Core.finalize_au_parameter_sets(state.core, au, parameter_sets,
        strip?: remove_parameter_sets_from_stream?(Core.output_stream_structure(state.core)),
        repeat?: state.repeat_parameter_sets,
        keyframe?: keyframe?(au)
      )

    {au, stream_format_actions, state}
  end

  defp handle_stream_format_parameter_sets(parameter_sets, last_sent_stream_format, state) do
    if remove_parameter_sets_from_stream?(Core.output_stream_structure(state.core)) do
      {parsed_parameter_sets, core} = Core.parse_parameter_sets(state.core, parameter_sets)

      cache_and_maybe_stream_format(parsed_parameter_sets, last_sent_stream_format, %{
        state
        | core: core
      })
    else
      {[], %{state | core: Core.set_frame_prefix(state.core, parameter_sets)}}
    end
  end

  # Caches the given parameter sets and emits a new stream format if they changed it.
  defp cache_and_maybe_stream_format(parameter_sets, last_sent_stream_format, state) do
    state = %{state | core: Core.cache_parameter_sets(state.core, parameter_sets)}

    stream_format_candidate =
      generate_stream_format(parameter_sets, last_sent_stream_format, state)

    if stream_format_candidate in [last_sent_stream_format, nil] do
      {[], state}
    else
      {[stream_format: {:output, stream_format_candidate}], state}
    end
  end

  defp incoming_parameter_sets(:annexb, _parameter_sets, true, state),
    do: state.initial_parameter_sets

  defp incoming_parameter_sets(:annexb, _parameter_sets, false, _state), do: []

  defp incoming_parameter_sets(_structure, parameter_sets, _is_first, state),
    do: Core.filter_new_parameter_sets(state.core, parameter_sets)

  defp prepare_buffer_actions(au, keyframe?, state) do
    {should_forward?, skip_until_keyframe?} =
      Utils.should_forward_au(au, keyframe?, state.skip_until_keyframe, NALuParser)

    state = %{state | skip_until_keyframe: skip_until_keyframe?}

    if should_forward? do
      {pts, dts} = NALuParser.get_first_vcl_nalu(au).timestamps

      buffers =
        Utils.wrap_into_buffer(
          au,
          pts,
          dts,
          keyframe?,
          state.output_alignment,
          Core.output_stream_structure(state.core),
          @metadata_key
        )

      {[buffer: {:output, buffers}], state}
    else
      {[], state}
    end
  end

  # Codec-specific decisions, driven by this element.

  defp parse_raw_input_stream_structure(stream_format) do
    {alignment, input_raw_stream_structure} =
      case stream_format do
        %RemoteStream{} ->
          {:bytestream, :annexb}

        %H264{alignment: alignment, stream_structure: stream_structure} ->
          {alignment, stream_structure}
      end

    case input_raw_stream_structure do
      :annexb ->
        {alignment, :annexb, []}

      {avc, dcr} ->
        %{nalu_length_size: nalu_length_size, spss: spss, ppss: ppss} =
          DecoderConfigurationRecord.parse(dcr)

        {alignment, {avc, nalu_length_size}, spss ++ ppss}
    end
  end

  defp remove_parameter_sets_from_stream?({:avc1, _nalu_length_size}), do: true
  defp remove_parameter_sets_from_stream?(_stream_structure), do: false

  defp generate_stream_format(parameter_sets, last_sent_stream_format, state) do
    latest_sps = parameter_sets |> Enum.filter(&(&1.type == :sps)) |> List.last()

    output_raw_stream_structure =
      case Core.output_stream_structure(state.core) do
        :annexb ->
          :annexb

        {avc, _nalu_length_size} = output_stream_structure ->
          cached = Core.cached_parameter_sets(state.core)
          spss = cached |> Enum.filter(&(&1.type == :sps)) |> Enum.map(& &1.payload)
          ppss = cached |> Enum.filter(&(&1.type == :pps)) |> Enum.map(& &1.payload)

          {avc, DecoderConfigurationRecord.generate(spss, ppss, output_stream_structure)}
      end

    case {latest_sps, last_sent_stream_format} do
      {nil, nil} ->
        nil

      {nil, last_sent_stream_format} ->
        %{last_sent_stream_format | stream_structure: output_raw_stream_structure}

      {latest_sps, _last_sent_stream_format} ->
        sps = latest_sps.parsed_fields

        %H264{
          width: sps.width,
          height: sps.height,
          profile: sps.profile,
          framerate: Core.framerate(state.core),
          alignment: state.output_alignment,
          nalu_in_metadata?: true,
          stream_structure: output_raw_stream_structure
        }
    end
  end

  defp get_parameter_sets(au) do
    spss = Enum.filter(au, &(&1.type == :sps))
    ppss = Enum.filter(au, &(&1.type == :pps))
    spss ++ ppss
  end

  defp keyframe?(au), do: Enum.any?(au, &(&1.type == :idr))
end
