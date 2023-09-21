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
  * Receiving `%Membrane.RemoteStream{type: :bytestream}` results in the parser mode being set to `:bytestream`
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
  alias Membrane.Element.{Action, CallbackContext}

  alias Membrane.H26x.Parser

  @typedoc """
  Type referencing `Membrane.H264.stream_structure` type, in case of `:avc1` and `:avc3`
  stream structure, it contains an information about the size of each NALU's prefix describing
  their length.
  """
  @type stream_structure :: :annexb | {:avc1 | :avc3, nalu_length_size :: pos_integer()}

  def_input_pad :input,
    demand_unit: :buffers,
    demand_mode: :auto,
    accepted_format: any_of(%RemoteStream{type: :bytestream}, H264)

  def_output_pad :output,
    demand_mode: :auto,
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
                  | :annexb
                  | :avc1
                  | :avc3
                  | {:avc1 | :avc3, nalu_length_size :: pos_integer()},
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

                By default, the parser adds negative DTS offset to the timestamps,
                so that in case of frame reorder (which always happens when B frames
                are present) the DTS was always bigger than PTS. If that is not desired,
                you can set `add_dts_offset: false`.
                """
              ]

  @impl true
  def handle_init(_ctx, opts) do
    {[], Parser.new(:h264, opts, Membrane.H264.Parser.AUSplitter)}
  end

  @impl true
  def handle_stream_format(:input, stream_format, ctx, state) do
    old_stream_format = ctx.pads.output.stream_format

    case Parser.handle_stream_format(state, stream_format, old_stream_format) do
      {nil, state} -> {[], state}
      {stream_format, state} -> {[stream_format: {:output, stream_format}], state}
    end
  end

  @impl true
  def handle_process(:input, %Membrane.Buffer{} = buffer, ctx, state) do
    Parser.handle_process(state, buffer, ctx.pads.output.stream_format)
  end

  @impl true
  def handle_end_of_stream(:input, ctx, state) do
    {actions, state} = Parser.handle_end_of_stream(state, ctx.pads.output.stream_format)

    if stream_format_sent?(actions, ctx) do
      {actions ++ [end_of_stream: :output], state}
    else
      {[], state}
    end
  end

  @spec stream_format_sent?([Action.t()], CallbackContext.t()) :: boolean()
  defp stream_format_sent?(actions, %{pads: %{output: %{stream_format: nil}}}),
    do: Enum.any?(actions, &match?({:stream_format, _stream_format}, &1))

  defp stream_format_sent?(_actions, _ctx), do: true
end
