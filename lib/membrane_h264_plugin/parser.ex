defmodule Membrane.H264.Parser do
  @moduledoc """
  Membrane element providing parser for H264 encoded video stream.

  The parser:
  * prepares and sends the appropriate stream format, based on information provided in the stream and via the element's options
  * splits the incoming stream into h264 access units - each buffer being output is a `Membrane.Buffer` struct with a
  binary payload of a single access unit
  * enriches the output buffers with the metadata describing the way the access unit is split into NAL units, type of each NAL unit
  making up the access unit and the information if the access unit hold a keyframe.

  The parser works in one of three possible modes, depending on the structure of the input buffers:
  * `:bytestream` - each input buffer contains some part of h264 stream's payload, but not necessary a logical
  h264 unit (like NAL unit or an access unit). Can be used for i.e. for parsing the stream read from the file.
  * `:nalu_aligned` - each input buffer contains a single NAL unit's payload
  * `:au_aligned` - each input buffer contains a single access unit's payload

  The parser's mode is set automatically, based on the input stream format received by that element:
  * Receiving `%Membrane.RemoteStream{type: :bytestream}` results in the parser mode being set to `:bytestream`
  * Receiving `%Membrane.H264.RemoteStream{alignment: :nalu}` results in the parser mode being set to `:nalu_aligned`
  * Receiving `%Membrane.H264.RemoteStream{alignment: :au}` results in the parser mode being set to `:au_aligned`

  The distinguishment between parser modes was introduced to eliminate the redundant operations and to provide a reliable way
  for rewriting of timestamps:
  * in the `:bytestream` mode:
    * if option `:framerate` is set to nil, the output buffers have their `:pts` and `:dts` set to nil
    * if framerate is specified, `:pts` and `:dts` will be generated automatically, based on that framerate, starting from 0
     This may only be used with h264 profiles `:baseline` and `:constrained_baseline`, where `PTS==DTS`.
  * in the `:nalu_aligned` mode, the output buffers have their `:pts` and `:dts` set to `:pts` and `:dts` of the
   input buffer that was holding the first NAL unit making up given access unit (that is being sent inside that output buffer).
  * in the `:au_aligned` mode, the output buffers have their `:pts` and `:dts` set to `:pts` and `:dts` of the input buffer
  (holding the whole access unit being output)
  """

  @typedoc """
  Type referencing `Membrane.H264.stream_type_t` type, but instead of whole DCR it only contains
  an information about the size of each NALU's prefix describing their length.
  """
  @type parsed_stream_type_t :: :annexb | {:avcc, nalu_length_size :: pos_integer()}

  use Membrane.Filter

  require Membrane.Logger

  alias Membrane.{Buffer, H264, RemoteStream}
  alias Membrane.H264.Parser.{AUSplitter, Format, NALuParser, NALuSplitter}

  alias __MODULE__.DecoderConfigurationRecord

  @annexb_prefix_code <<0, 0, 0, 1>>
  @nalu_length_size 4

  def_input_pad :input,
    demand_unit: :buffers,
    demand_mode: :auto,
    accepted_format:
      any_of(
        %RemoteStream{type: :bytestream},
        %H264.RemoteStream{alignment: alignment} when alignment in [:nalu, :au],
        %H264{}
      )

  def_output_pad :output,
    demand_mode: :auto,
    accepted_format:
      any_of(%H264{alignment: :au, nalu_in_metadata?: true}, %H264{alignment: :nalu})

  def_options sps: [
                spec: binary() | [binary()],
                default: [],
                description: """
                Sequence Parameter Set NAL unit binary payload - if absent in the stream, should
                be provided via this option.
                """
              ],
              pps: [
                spec: binary() | [binary()],
                default: [],
                description: """
                Picture Parameter Set NAL unit binary payload - if absent in the stream, should
                be provided via this option.
                """
              ],
              framerate: [
                spec: {pos_integer(), pos_integer()} | nil,
                default: nil,
                description: """
                Framerate of the video, represented as a tuple consisting of a numerator and the
                denominator.
                Its value will be sent inside the output Membrane.H264 stream format.
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
              skip_until_keyframe?: [
                spec: boolean(),
                default: false,
                description: """
                Determines whether to drop the stream until the first key frame is received.

                Defaults to false.
                """
              ],
              repeat_parameter_sets: [
                spec: boolean(),
                default: false,
                description: """
                Repeat all parameter sets (`sps` and `pps`) on each IDR picture.

                Parameter sets may be retrieved from:
                  * The bytestream
                  * `Parser` options.
                  * Decoder Configuration Record, sent as decoder_configuration_record
                  in `Membrane.H264.RemoteStream` stream format
                """
              ],
              output_parsed_stream_type: [
                spec: :annexb | :avcc | {:avcc, nalu_length_size :: pos_integer()},
                default: :annexb,
                description: """
                format of the outgoing H264 stream, if set to `:annexb` NALUs will be separated by
                a start code (0x(00)000001) or if set to `:avcc` they will be prefixed by their size.
                Additionally for `avcc` a tuple can be passed containg `:avcc` atom and
                `nalu_length_size` that determines the size in bytes of each NALU's field
                describing their length (by default 4).
                """
              ]

  @impl true
  def handle_init(_ctx, opts) do
    output_parsed_stream_type =
      case opts.output_parsed_stream_type do
        :avcc -> {:avcc, @nalu_length_size}
        stream_type -> stream_type
      end

    state = %{
      nalu_splitter: nil,
      nalu_parser: nil,
      au_splitter: AUSplitter.new(),
      mode: nil,
      profile: nil,
      previous_timestamps: {nil, nil},
      framerate: opts.framerate,
      au_counter: 0,
      output_alignment: opts.output_alignment,
      frame_prefix: <<>>,
      skip_until_keyframe?: opts.skip_until_keyframe?,
      repeat_parameter_sets?: opts.repeat_parameter_sets,
      cached_sps: %{},
      cached_pps: %{},
      initial_sps: parse_initial_parameters(opts.sps),
      initial_pps: parse_initial_parameters(opts.pps),
      input_raw_stream_type: nil,
      output_parsed_stream_type: output_parsed_stream_type
    }

    {[], state}
  end

  @impl true
  def handle_stream_format(:input, stream_format, _ctx, state) do
    {mode, input_raw_stream_type} =
      case stream_format do
        %RemoteStream{type: :bytestream} ->
          {:bytestream, :annexb}

        %H264.RemoteStream{alignment: alignment, stream_type: stream_type} ->
          {alignment, stream_type}

        %H264{alignment: alignment, stream_type: stream_type} ->
          {alignment, stream_type}
      end

    mode =
      case mode do
        :au -> :au_aligned
        :nalu -> :nalu_aligned
        mode -> mode
      end

    input_parsed_stream_type = parse_raw_stream_type(input_raw_stream_type)

    state = %{
      state
      | mode: mode,
        frame_prefix: get_frame_prefix(input_raw_stream_type, state),
        input_raw_stream_type: input_raw_stream_type,
        nalu_parser: NALuParser.new(input_parsed_stream_type, state.output_parsed_stream_type),
        nalu_splitter: NALuSplitter.new(input_parsed_stream_type)
    }

    {[], state}
  end

  @impl true
  def handle_process(:input, %Membrane.Buffer{} = buffer, _ctx, state) do
    {payload, state} =
      case state.frame_prefix do
        <<>> -> {buffer.payload, state}
        prefix -> {prefix <> buffer.payload, %{state | frame_prefix: <<>>}}
      end

    {nalus_payloads_list, nalu_splitter} = NALuSplitter.split(payload, state.nalu_splitter)

    {nalus_payloads_list, nalu_splitter} =
      if state.mode != :bytestream do
        {last_nalu_payload, nalu_splitter} = NALuSplitter.flush(nalu_splitter)

        if last_nalu_payload != <<>> do
          {nalus_payloads_list ++ [last_nalu_payload], nalu_splitter}
        else
          {nalus_payloads_list, nalu_splitter}
        end
      else
        {nalus_payloads_list, nalu_splitter}
      end

    {nalus, nalu_parser} =
      Enum.map_reduce(nalus_payloads_list, state.nalu_parser, fn nalu_payload, nalu_parser ->
        NALuParser.parse(nalu_payload, nalu_parser)
      end)

    {access_units, au_splitter} = AUSplitter.split(nalus, state.au_splitter)

    {access_units, au_splitter} =
      if state.mode == :au_aligned do
        {last_au, au_splitter} = AUSplitter.flush(au_splitter)
        {access_units ++ [last_au], au_splitter}
      else
        {access_units, au_splitter}
      end

    {actions, state} = prepare_actions_for_aus(access_units, state, buffer.pts, buffer.dts)

    state = %{
      state
      | nalu_splitter: nalu_splitter,
        nalu_parser: nalu_parser,
        au_splitter: au_splitter
    }

    #    IO.inspect(actions, label: "actions")
    {actions, state}
  end

  @impl true
  def handle_end_of_stream(:input, ctx, state) when state.mode != :au_aligned do
    {last_nalu_payload, nalu_splitter} = NALuSplitter.flush(state.nalu_splitter)

    {{access_units, au_splitter}, nalu_parser} =
      if last_nalu_payload != <<>> do
        {last_nalu, nalu_parser} = NALuParser.parse(last_nalu_payload, state.nalu_parser)
        {AUSplitter.split([last_nalu], state.au_splitter), nalu_parser}
      else
        {{[], state.au_splitter}, state.nalu_parser}
      end

    {remaining_nalus, au_splitter} = AUSplitter.flush(au_splitter)
    maybe_improper_aus = access_units ++ [remaining_nalus]

    {actions, state} = prepare_actions_for_aus(maybe_improper_aus, state)
    actions = if stream_format_sent?(actions, ctx), do: actions, else: []

    state = %{
      state
      | nalu_splitter: nalu_splitter,
        nalu_parser: nalu_parser,
        au_splitter: au_splitter
    }

    {actions ++ [end_of_stream: :output], state}
  end

  @impl true
  def handle_end_of_stream(_pad, _ctx, state) do
    {[end_of_stream: :output], state}
  end

  defp parse_initial_parameters(<<>>), do: []
  defp parse_initial_parameters(pss) when is_binary(pss), do: [pss]
  defp parse_initial_parameters(pss), do: pss

  defp parse_raw_stream_type(:annexb), do: :annexb

  defp parse_raw_stream_type({:avcc, dcr}) do
    {:ok, %{length_size_minus_one: length_size_minus_one}} = DecoderConfigurationRecord.parse(dcr)
    {:avcc, length_size_minus_one + 1}
  end

  defp get_frame_prefix(:annexb, state) do
    Enum.concat([[<<>>], state.initial_sps, state.initial_pps])
    |> Enum.join(@annexb_prefix_code)
  end

  defp get_frame_prefix({:avcc, dcr}, state) do
    {:ok, %{sps: sps, pps: pps, length_size_minus_one: length_size_minus_one}} =
      DecoderConfigurationRecord.parse(dcr)

    nalu_length_size = length_size_minus_one + 1

    Enum.concat([state.initial_sps, state.initial_pps, sps, pps])
    |> Enum.map(fn nalu ->
      <<byte_size(nalu)::integer-size(nalu_length_size)-unit(8), nalu::binary>>
    end)
    |> Enum.join()
  end

  defp prepare_actions_for_aus(aus, state, buffer_pts \\ nil, buffer_dts \\ nil) do
    {actions, state} =
      Enum.flat_map_reduce(aus, state, fn au, state ->
        cnt = state.au_counter
        profile = state.profile

        au = maybe_add_parameter_sets(au, state) |> delete_duplicate_parameter_sets()
        state = cache_parameter_sets(state, au)
        {sps_actions, profile} = maybe_parse_sps(au, state, profile)

        {pts, dts} = prepare_timestamps(buffer_pts, buffer_dts, state, profile, cnt)

        state = %{
          state
          | profile: profile,
            au_counter: cnt + 1
        }

        has_seen_keyframe? =
          Enum.all?(au, &(&1.status == :valid)) and Enum.any?(au, &(&1.type == :idr))

        state = %{
          state
          | skip_until_keyframe?: state.skip_until_keyframe? and not has_seen_keyframe?
        }

        buffers_actions =
          if Enum.any?(au, &(&1.status == :error)) or state.skip_until_keyframe? do
            []
          else
            [
              buffer:
                {:output,
                 wrap_into_buffer(
                   au,
                   pts,
                   dts,
                   state.output_alignment
                 )}
            ]
          end

        {sps_actions ++ buffers_actions, state}
      end)

    state =
      if state.mode == :nalu_aligned and state.previous_timestamps != {buffer_pts, buffer_dts} do
        %{state | previous_timestamps: {buffer_pts, buffer_dts}}
      else
        state
      end

    {actions, state}
  end

  defp maybe_parse_sps(au, state, profile) do
    case Enum.find(au, &(&1.type == :sps)) do
      nil ->
        {[], profile}

      sps_nalu ->
        format =
          Format.from_sps(sps_nalu,
            framerate: state.framerate,
            output_alignment: state.output_alignment
          )
          |> Map.put(:stream_type, get_output_raw_stream_type(state))

        {[stream_format: {:output, format}], format.profile}
    end
  end

  defp get_output_raw_stream_type(%{output_parsed_stream_type: :annexb}) do
    :annexb
  end

  defp get_output_raw_stream_type(%{
         output_parsed_stream_type: {:avcc, nalu_length_size},
         cached_sps: spss
       }) do
    sps_dqrs =
      Enum.map(spss, fn {_id, sps} ->
        fields = sps.parsed_fields

        profile = fields.profile_idc

        compatibility =
          <<fields.constraint_set0::integer-1, fields.constraint_set1::integer-1,
            fields.constraint_set2::integer-1, fields.constraint_set3::integer-1,
            fields.constraint_set4::integer-1, fields.constraint_set5::integer-1,
            fields.reserved_zero_2bits::integer-2>>

        level = fields.level_idc

        <<1::8, profile::integer-8, compatibility::binary, level::integer-8, 0b111111::6,
          nalu_length_size - 1::2-integer, 0b111::3, 0::5, 0::8>>
      end)
      |> Enum.uniq()

    if length(sps_dqrs) > 1 do
      raise("SPS parameters should be the same for all sets but are different")
    end

    {:avcc, hd(sps_dqrs)}
  end

  defp prepare_timestamps(_buffer_pts, _buffer_dts, state, profile, frame_order_number)
       when state.mode == :bytestream do
    cond do
      state.framerate == nil or profile == nil ->
        {nil, nil}

      h264_profile_tsgen_supported?(profile) ->
        generate_ts_with_constant_framerate(
          state.framerate,
          frame_order_number,
          frame_order_number
        )

      true ->
        raise("Timestamp generation for H264 profile `#{inspect(profile)}` is unsupported")
    end
  end

  defp prepare_timestamps(buffer_pts, buffer_dts, state, _profile, _frame_order_number)
       when state.mode == :nalu_aligned do
    if state.previous_timestamps == {nil, nil} do
      {buffer_pts, buffer_dts}
    else
      state.previous_timestamps
    end
  end

  defp prepare_timestamps(buffer_pts, buffer_dts, state, _profile, _frame_order_number)
       when state.mode == :au_aligned do
    {buffer_pts, buffer_dts}
  end

  defp maybe_add_parameter_sets(au, %{repeat_parameter_sets?: false}), do: au

  defp maybe_add_parameter_sets(au, state) do
    if idr_au?(au),
      do: Map.values(state.cached_sps) ++ Map.values(state.cached_pps) ++ au,
      else: au
  end

  defp delete_duplicate_parameter_sets(au) do
    if idr_au?(au), do: Enum.uniq(au), else: au
  end

  defp cache_parameter_sets(state, au) do
    sps =
      Enum.filter(au, &(&1.type == :sps))
      |> Enum.map(&{&1.parsed_fields.seq_parameter_set_id, &1})
      |> Map.new()
      |> Map.merge(state.cached_sps)

    pps =
      Enum.filter(au, &(&1.type == :pps))
      |> Enum.map(&{&1.parsed_fields.pic_parameter_set_id, &1})
      |> Map.new()
      |> Map.merge(state.cached_pps)

    %{state | cached_sps: sps, cached_pps: pps}
  end

  defp idr_au?(au), do: :idr in Enum.map(au, & &1.type)

  defp wrap_into_buffer(access_unit, pts, dts, :au) do
    metadata = prepare_au_metadata(access_unit)

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

  defp wrap_into_buffer(access_unit, pts, dts, :nalu) do
    access_unit
    |> Enum.zip(prepare_nalus_metadata(access_unit))
    |> Enum.map(fn {nalu, metadata} ->
      %Buffer{
        payload: nalu.payload,
        metadata: metadata,
        pts: pts,
        dts: dts
      }
    end)
  end

  defp prepare_au_metadata(nalus) do
    is_keyframe? = Enum.any?(nalus, fn nalu -> nalu.type == :idr end)

    nalus =
      nalus
      |> Enum.with_index()
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
            put_in(metadata, [:metadata, :h264, :new_access_unit], %{key_frame?: is_keyframe?})
          else
            metadata
          end

        {metadata, nalu_start + byte_size(nalu.payload)}
      end)
      |> elem(0)

    %{h264: %{key_frame?: is_keyframe?, nalus: nalus}}
  end

  defp prepare_nalus_metadata(nalus) do
    is_keyframe? = Enum.any?(nalus, fn nalu -> nalu.type == :idr end)

    Enum.with_index(nalus)
    |> Enum.map(fn {nalu, i} ->
      %{h264: %{type: nalu.type}}
      |> Bunch.then_if(
        i == 0,
        &put_in(&1, [:h264, :new_access_unit], %{key_frame?: is_keyframe?})
      )
      |> Bunch.then_if(i == length(nalus) - 1, &put_in(&1, [:h264, :end_access_unit], true))
    end)
  end

  defp stream_format_sent?(actions, %{pads: %{output: %{stream_format: nil}}}),
    do: Enum.any?(actions, &match?({:stream_format, _stream_format}, &1))

  defp stream_format_sent?(_actions, _ctx), do: true

  defp h264_profile_tsgen_supported?(profile),
    do: profile in [:baseline, :constrained_baseline]

  defp generate_ts_with_constant_framerate(
         {frames, seconds} = _framerate,
         presentation_order_number,
         decoding_order_number
       ) do
    pts = div(presentation_order_number * seconds * Membrane.Time.second(), frames)
    dts = div(decoding_order_number * seconds * Membrane.Time.second(), frames)
    {pts, dts}
  end
end
