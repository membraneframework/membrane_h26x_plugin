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
  * Receiving `%Membrane.RemoteStream{type: :bytestream}` results in the parser mode being set to `:bytestream`
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
  alias Membrane.H265.{DecoderConfigurationRecord, AUSplitter, NALuParser, AUTimestampGenerator}

  @behaviour Membrane.H26x.Parser

  @nalu_length_size 4
  @metadata_key :h265

  @typep stream_format :: Membrane.StreamFormat.t()
  @typep state :: Membrane.Element.state()
  @typep callback_return :: Membrane.Element.Base.callback_return()

  def_input_pad :input,
    flow_control: :auto,
    accepted_format: any_of(%RemoteStream{type: :bytestream}, H265)

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
                  | :annexb
                  | :hvc1
                  | :hev1
                  | {:hvc1 | :hev1, nalu_length_size :: pos_integer()},
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

                By default, the parser adds negative DTS offset to the timestamps,
                so that in case of frame reorder (which always happens when B frames
                are present) the DTS is always bigger than PTS. If that is not desired,
                you can set `add_dts_offset: false`.

                The calculated DTS/PTS may be wrong since we base it on access units' POC (Picture Order Count).
                We assume here that the POC is continuous on a CVS (Coded Video Sequence) which is
                not guaranteed by the H265 specification. An example where POC values may not be continuous is
                when generating sub-bitstream from the main stream by deleting access units belonging to a
                higher temporal sub-layer.
                """
              ]

  @impl true
  def handle_init(ctx, opts) do
    output_stream_structure =
      case opts.output_stream_structure do
        :hvc1 -> {:hvc1, @nalu_length_size}
        :hev1 -> {:hev1, @nalu_length_size}
        stream_structure -> stream_structure
      end

    initial_parameter_sets = {opts.vpss, opts.spss, opts.ppss}

    opts =
      Map.from_struct(opts)
      |> Map.drop([:vpss, :spss, :ppss])
      |> Map.put(:output_stream_structure, output_stream_structure)
      |> Map.put(:initial_parameter_sets, initial_parameter_sets)

    Membrane.H26x.Parser.handle_init(
      ctx,
      opts,
      AUTimestampGenerator,
      NALuParser,
      AUSplitter,
      @metadata_key
    )
  end

  @impl true
  def handle_stream_format(:input, stream_format, ctx, state) do
    Membrane.H26x.Parser.handle_stream_format(__MODULE__, stream_format, ctx, state)
  end

  @impl true
  def handle_buffer(:input, %Membrane.Buffer{} = buffer, ctx, state) do
    Membrane.H26x.Parser.handle_buffer(__MODULE__, buffer, ctx, state)
  end

  @impl true
  def handle_end_of_stream(:input, ctx, state) when state.mode != :au_aligned do
    Membrane.H26x.Parser.handle_end_of_stream(__MODULE__, ctx, state)
  end

  @impl true
  def handle_end_of_stream(_pad, _ctx, state) do
    {[end_of_stream: :output], state}
  end

  @impl true
  def parse_raw_input_stream_structure(stream_format) do
    {alignment, input_raw_stream_structure} =
      case stream_format do
        %RemoteStream{type: :bytestream} ->
          {:bytestream, :annexb}

        %H265{alignment: alignment, stream_structure: stream_structure} ->
          {alignment, stream_structure}
      end

    case input_raw_stream_structure do
      :annexb ->
        {alignment, :annexb, {[], [], []}}

      {hevc, dcr} ->
        %{nalu_length_size: nalu_length_size, vpss: vpss, spss: spss, ppss: ppss} =
          DecoderConfigurationRecord.parse(dcr)

        {alignment, {hevc, nalu_length_size}, {vpss, spss, ppss}}
    end
  end

  @impl true
  def remove_parameter_sets_from_stream?({:hvc1, _nalu_length_size}), do: true
  def remove_parameter_sets_from_stream?(_stream_structure), do: false

  @impl true
  def generate_stream_format(parameter_sets, last_sent_stream_format, state) do
    latest_sps = List.last(elem(parameter_sets, 1))

    output_raw_stream_structure =
      case state.output_stream_structure do
        :annexb ->
          :annexb

        {hevc, _nalu_length_size} ->
          {vpss, spss, ppss} = state.cached_parameter_sets

          {hevc,
           DecoderConfigurationRecord.generate(vpss, spss, ppss, state.output_stream_structure)}
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
          framerate: state.framerate,
          alignment: state.output_alignment,
          nalu_in_metadata?: true,
          stream_structure: output_raw_stream_structure
        }
    end
  end

  @impl true
  def get_parameter_sets(au) do
    Enum.reduce(au, {[], [], []}, fn nalu, {vpss, spss, ppss} ->
      case nalu.type do
        :vps -> {vpss ++ [nalu], spss, ppss}
        :sps -> {vpss, spss ++ [nalu], ppss}
        :pps -> {vpss, spss, ppss ++ [nalu]}
        _other -> {vpss, spss, ppss}
      end
    end)
  end

  @impl true
  def keyframe?(au), do: Enum.any?(au, &NALuTypes.is_irap_nalu_type(&1.type))
end
