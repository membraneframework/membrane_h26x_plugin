defmodule Membrane.H265.Parser do
  @moduledoc """
  Membrane element providing parser for H265 encoded video stream.

  The parser:
  * prepares and sends the appropriate stream format, based on information provided in the stream and via the element's options
  * splits the incoming stream into H265 access units - each buffer being output is a `Membrane.Buffer` struct with a
  binary payload of a single access unit
  * enriches the output buffers with the metadata describing the way the access unit is split into NAL units, type of each NAL unit
  making up the access unit and the information if the access unit hold a keyframe.

  The parser works in one of three possible modes, depending on the structure of the input buffers:
  * `:bytestream` - each input buffer contains some part of H265 stream's payload, but not necessary a logical
  H265 unit (like NAL unit or an access unit). Can be used for i.e. for parsing the stream read from the file.
  * `:nalu_aligned` - each input buffer contains a single NAL unit's payload
  * `:au_aligned` - each input buffer contains a single access unit's payload

  The parser's mode is set automatically, based on the input stream format received by that element:
  * Receiving `Membrane.RemoteStream` results in the parser mode being set to `:bytestream`
  * Receiving `%Membrane.H265{alignment: :nalu}` results in the parser mode being set to `:nalu_aligned`.
  * Receiving `%Membrane.H265{alignment: :au}` results in the parser mode being set to `:au_aligned`.

  The parser also allows for conversion between stream structures. The available structures are:
  * Annex B, `:annexb` - In a stream with this structure each NAL unit is prefixed by three or
  four-byte start code (`0x(00)000001`) that allows to identify boundaries between them.
  * hvc1, `:hvc1` - In such stream a DCR (Decoder Configuration Record) is included in `stream_format`
  and NALUs lack the start codes, but are prefixed with their length. The length of these prefixes
  is contained in the stream's DCR. PPSs, SPSs and VPSs (Picture Parameter Sets, Sequence Parameter Sets and Video Parameter Sets)
  are transported in the DCR.
  * hev1, `:hev1` - The same as hvc1, only that parameter sets may be also present in the stream (in-band).
  """

  use Membrane.Filter

  require Membrane.H265.NALuTypes, as: NALuTypes

  alias Membrane.{H265, RemoteStream}
  alias Membrane.H265.{AUSplitter, AUTimestampGenerator, DecoderConfigurationRecord, NALuParser}
  alias Membrane.H26x.Parser.{Core, Utils}

  @nalu_length_size 4
  @metadata_key :h265

  def_input_pad :input,
    flow_control: :auto,
    accepted_format: any_of(RemoteStream, H265)

  def_output_pad :output,
    flow_control: :auto,
    accepted_format:
      %H265{alignment: alignment, nalu_in_metadata?: true} when alignment in [:nalu, :au]

  def_options vpss: [
                spec: [binary()],
                default: [],
                description: """
                Video Parameter Set NAL unit binary payloads - if absent in the stream, may
                be provided via this option (only available for `:annexb` output stream format)

                Any decoder conforming to the profiles specified in "Annex A" of ITU/IEC H265 (08/21),
                but does not support INBLD may discard all VPS NAL units.
                """
              ],
              spss: [
                spec: [binary()],
                default: [],
                description: """
                Sequence Parameter Set NAL unit binary payloads - if absent in the stream, should
                be provided via this option (only available for `:annexb` output stream format).
                """
              ],
              ppss: [
                spec: [binary()],
                default: [],
                description: """
                Picture Parameter Set NAL unit binary payloads - if absent in the stream, should
                be provided via this option (only available for `:annexb` output stream format).
                """
              ],
              skip_until_keyframe: [
                spec: boolean(),
                default: true,
                description: """
                Determines whether to drop the stream until the first key frame is received.

                Defaults to true.
                """
              ],
              repeat_parameter_sets: [
                spec: boolean(),
                default: false,
                description: """
                Repeat all parameter sets (`vps`, `sps` and `pps`) on each IRAP picture.

                Parameter sets may be retrieved from:
                  * The stream
                  * `Parser` options.
                  * `Decoder Configuration Record`, sent in `:hcv1` and `:hev1` stream types
                """
              ],
              output_alignment: [
                spec: :au | :nalu,
                default: :au,
                description: """
                Alignment of the buffers produced as an output of the parser.
                If set to `:au`, each output buffer will be a single access unit.
                Otherwise, if set to `:nalu`, each output buffer will be a single NAL unit.
                """
              ],
              output_stream_structure: [
                spec:
                  nil
                  | stream_structure()
                  | :hvc1
                  | :hev1,
                default: nil,
                description: """
                format of the outgoing H265 stream, if set to `:annexb` NALUs will be separated by
                a start code (0x(00)000001) or if set to `:hvc1` or `:hev1` they will be prefixed by their size.
                Additionally for `:hvc1` and `:hev1` a tuple can be passed containing the atom and
                `nalu_length_size` that determines the size in bytes of each NALU's field
                describing their length (by default 4). In hvc1 output streams the PPSs, SPSs and VPSs will be
                transported in the DCR, when in hev1 they will be present only in the stream (in-band).
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
                to video getting out of sync with other media, therefore H265 stream
                should be kept in a container that stores the timestamps alongside.

                PTS are derived from each frame's presentation order, recovered by
                sorting the access units by their Picture Order Count (POC). Because
                PTS are based on the relative POC order rather than the absolute POC
                values, the timestamps stay correct even when POC values are not
                continuous within a Coded Video Sequence (e.g. when a sub-bitstream is
                produced by dropping a higher temporal sub-layer).

                Recovering the presentation order requires buffering (reordering) a
                bounded number of access units before emitting them, which introduces
                a constant latency of that many frame durations. The buffer depth is
                taken from the SPS `sps_max_num_reorder_pics`, so the latency is as low
                as the stream allows; when the stream can't reorder frames (that value
                being 0) the buffering is disabled and no latency is added.

                By default, the parser adds negative DTS offset to the timestamps,
                so that in case of frame reorder (which always happens when B frames
                are present) the DTS is always bigger than PTS. If that is not desired,
                you can set `add_dts_offset: false`.
                """
              ]

  @typedoc """
  Format of the H265 stream, if set to `:annexb` NALUs will be separated by
  a start code (0x(00)000001) or if set to `:hvc1` or `:hev1` they will be
  prefixed by their size.
  """
  @type stream_structure ::
          :annexb | {codec_tag :: :hvc1 | :hev1, nalu_length_size :: pos_integer()}

  @impl true
  def handle_init(_ctx, opts) do
    output_stream_structure =
      case opts.output_stream_structure do
        :hvc1 -> {:hvc1, @nalu_length_size}
        :hev1 -> {:hev1, @nalu_length_size}
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
      initial_parameter_sets: opts.vpss ++ opts.spss ++ opts.ppss
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
      process_stream_format_parameter_sets(
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
      {au, stream_format_actions, state} = process_au_parameter_sets(au, ctx, state)
      {buffer_actions, state} = prepare_buffer_actions(au, keyframe?(au), state)
      {stream_format_actions ++ buffer_actions, state}
    end)
  end

  defp process_au_parameter_sets(au, ctx, state) do
    old_stream_format = ctx.pads.output.stream_format
    parameter_sets = get_parameter_sets(au)

    {stream_format_actions, state} =
      process_new_parameter_sets(parameter_sets, old_stream_format, state)

    au =
      if remove_parameter_sets_from_stream?(Core.output_stream_structure(state.core)) do
        Core.remove_parameter_sets(au, parameter_sets)
      else
        au
        |> maybe_add_parameter_sets(state)
        |> maybe_dedup_parameter_sets()
      end

    {au, stream_format_actions, state}
  end

  defp process_new_parameter_sets(parameter_sets, last_sent_stream_format, state) do
    state = %{state | core: Core.cache_parameter_sets(state.core, parameter_sets)}

    stream_format_candidate =
      generate_stream_format(parameter_sets, last_sent_stream_format, state)

    if stream_format_candidate in [last_sent_stream_format, nil] do
      {[], state}
    else
      {[stream_format: {:output, stream_format_candidate}], state}
    end
  end

  defp process_stream_format_parameter_sets(parameter_sets, last_sent_stream_format, state) do
    if remove_parameter_sets_from_stream?(Core.output_stream_structure(state.core)) do
      {parsed_parameter_sets, core} = Core.parse_parameter_sets(state.core, parameter_sets)

      process_new_parameter_sets(parsed_parameter_sets, last_sent_stream_format, %{
        state
        | core: core
      })
    else
      {[], %{state | core: Core.set_frame_prefix(state.core, parameter_sets)}}
    end
  end

  defp incoming_parameter_sets(:annexb, _parameter_sets, true, state),
    do: state.initial_parameter_sets

  defp incoming_parameter_sets(:annexb, _parameter_sets, false, _state), do: []

  defp incoming_parameter_sets(_structure, parameter_sets, _is_first, state),
    do: Core.filter_new_parameter_sets(state.core, parameter_sets)

  defp maybe_add_parameter_sets(au, %{repeat_parameter_sets: false}), do: au

  defp maybe_add_parameter_sets(au, state) do
    if keyframe?(au), do: Core.add_cached_parameter_sets(au, state.core), else: au
  end

  defp maybe_dedup_parameter_sets(au) do
    if keyframe?(au), do: Core.dedup_parameter_sets(au), else: au
  end

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

        %H265{alignment: alignment, stream_structure: stream_structure} ->
          {alignment, stream_structure}
      end

    case input_raw_stream_structure do
      :annexb ->
        {alignment, :annexb, []}

      {hevc, dcr} ->
        %{nalu_length_size: nalu_length_size, vpss: vpss, spss: spss, ppss: ppss} =
          DecoderConfigurationRecord.parse(dcr)

        {alignment, {hevc, nalu_length_size}, vpss ++ spss ++ ppss}
    end
  end

  defp remove_parameter_sets_from_stream?({:hvc1, _nalu_length_size}), do: true
  defp remove_parameter_sets_from_stream?(_stream_structure), do: false

  defp generate_stream_format(parameter_sets, last_sent_stream_format, state) do
    latest_sps = parameter_sets |> Enum.filter(&(&1.type == :sps)) |> List.last()

    output_raw_stream_structure =
      case Core.output_stream_structure(state.core) do
        :annexb ->
          :annexb

        {hevc, _nalu_length_size} = output_stream_structure ->
          cached = Core.cached_parameter_sets(state.core)
          vpss = Enum.filter(cached, &(&1.type == :vps))
          spss = Enum.filter(cached, &(&1.type == :sps))
          ppss = Enum.filter(cached, &(&1.type == :pps))

          {hevc, DecoderConfigurationRecord.generate(vpss, spss, ppss, output_stream_structure)}
      end

    case {latest_sps, last_sent_stream_format} do
      {nil, nil} ->
        nil

      {nil, last_sent_stream_format} ->
        %{last_sent_stream_format | stream_structure: output_raw_stream_structure}

      {latest_sps, _last_sent_stream_format} ->
        sps = latest_sps.parsed_fields

        %H265{
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
    vpss = Enum.filter(au, &(&1.type == :vps))
    spss = Enum.filter(au, &(&1.type == :sps))
    ppss = Enum.filter(au, &(&1.type == :pps))
    vpss ++ spss ++ ppss
  end

  defp keyframe?(au), do: Enum.any?(au, &NALuTypes.is_irap_nalu_type(&1.type))
end
