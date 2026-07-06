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
  alias Membrane.H26x.Parser.Utils

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

    state =
      Utils.init_state(codec(),
        output_stream_structure: output_stream_structure,
        generate_best_effort_timestamps: opts.generate_best_effort_timestamps,
        output_alignment: opts.output_alignment,
        skip_until_keyframe: opts.skip_until_keyframe,
        repeat_parameter_sets: opts.repeat_parameter_sets,
        initial_parameter_sets: opts.spss ++ opts.ppss
      )

    {[], state}
  end

  @impl true
  def handle_stream_format(:input, stream_format, ctx, state) do
    input = parse_raw_input_stream_structure(stream_format)
    Utils.handle_stream_format(input, Map.get(stream_format, :framerate), ctx, state)
  end

  @impl true
  def handle_buffer(:input, %Membrane.Buffer{} = buffer, ctx, state),
    do: Utils.handle_buffer(buffer, ctx, state)

  @impl true
  def handle_end_of_stream(:input, ctx, state)
      when ctx.pads.input.start_of_stream? and state.core.mode != :au_aligned,
      do: Utils.handle_end_of_stream(ctx, state)

  @impl true
  def handle_end_of_stream(_pad, _ctx, state) do
    {[end_of_stream: :output], state}
  end

  defp codec() do
    %{
      stream_format_module: H264,
      dcr_module: DecoderConfigurationRecord,
      keyframe_nalu_types: [:idr],
      parameter_set_nalu_types: [:sps, :pps],
      out_of_band_parameter_sets_codec_tags: [:avc1],
      nalu_parser_mod: NALuParser,
      au_splitter_mod: AUSplitter,
      au_timestamp_generator_mod: AUTimestampGenerator,
      metadata_key: @metadata_key
    }
  end

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
end
