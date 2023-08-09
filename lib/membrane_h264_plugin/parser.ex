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

  The distinction between parser modes was introduced to eliminate the redundant operations and to provide a reliable way
  for rewriting of timestamps:
  * in the `:bytestream` mode:
    * if option `:framerate` is set to nil, the output buffers have their `:pts` and `:dts` set to nil
    * if framerate is specified, `:pts` and `:dts` will be generated automatically, based on that framerate, starting from 0
     This may only be used with h264 profiles `:baseline` and `:constrained_baseline`, where `PTS==DTS`.
  * in the `:nalu_aligned` mode, the output buffers have their `:pts` and `:dts` set to `:pts` and `:dts` of the
   input buffer that was holding the first NAL unit making up given access unit (that is being sent inside that output buffer).
  * in the `:au_aligned` mode, the output buffers have their `:pts` and `:dts` set to `:pts` and `:dts` of the input buffer
  (holding the whole access unit being output)

  -- Input --
  on handle_stream_format:
  * annexb: cache options parameter sets
  * avc1: cache options and input dcr parameter sets
  * avc3: cache options and input dcr parameter sets

  on maybe_parse_sps:
  * annexb

  -- Output --
  on handle_stream_format:
  * annexb: put all cached parameter sets into frame prefix
  * avc1: put all cached parameter sets into dcr
  * avc3: put all cached parameter sets into frame prefix

  notes:
  * the dcr header may not be known until receiving the first AU
  * only initial parameters in dcr parameters section

  * should cached parameters always be sent on idr aus, even in avc3 output stream type?
  *

  """

  @typedoc """
  Type referencing `Membrane.H264.stream_type_t` type, but instead of whole DCR it only contains
  an information about the size of each NALU's prefix describing their length.
  """
  @type parsed_stream_type :: :annexb | {:avc1 | :avc3, nalu_length_size :: pos_integer()}

  @typep raw_stream_type :: :annexb | {:avc1 | :avc3, dcr :: binary()}
  @typep state :: Membrane.Element.state()
  @typep callback_return :: Membrane.Element.Base.callback_return()

  use Membrane.Filter

  require Membrane.Logger

  alias Membrane.{Buffer, H264, RemoteStream}
  alias Membrane.H264.Parser.{AUSplitter, Format, NALuParser, NALuSplitter, NALu}
  alias Membrane.Element.CallbackContext

  alias __MODULE__.DecoderConfigurationRecord

  @annexb_prefix_code <<0, 0, 0, 1>>
  @nalu_length_size 4

  def_input_pad :input,
    demand_unit: :buffers,
    demand_mode: :auto,
    accepted_format:
      any_of(
        %RemoteStream{type: :bytestream},
        %H264{},
        %H264.RemoteStream{alignment: alignment} when alignment in [:nalu, :au]
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
                  * The stream
                  * `Parser` options.
                  * Decoder Configuration Record, sent in `:acv1` and `:avc3` stream types
                """
              ],
              output_parsed_stream_type: [
                spec:
                  :annexb | :avc1 | :avc3 | {:avc1 | :avc3, nalu_length_size :: pos_integer()},
                default: :annexb,
                description: """
                format of the outgoing H264 stream, if set to `:annexb` NALUs will be separated by
                a start code (0x(00)000001) or if set to `:avc3` or `:avc1` they will be prefixed by their size.
                Additionally for `:avc1` and `:avc3` a tuple can be passed containing the atom and
                `nalu_length_size` that determines the size in bytes of each NALU's field
                describing their length (by default 4). In avc1 streams PPSs and SPSs are transported
                in the DCR, when in avc3 they may be also present in the stream (in-band).
                """
              ]

  @impl true
  def handle_init(_ctx, opts) do
    output_parsed_stream_type =
      case opts.output_parsed_stream_type do
        :avc3 -> {:avc3, @nalu_length_size}
        :avc1 -> {:avc1, @nalu_length_size}
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
      cached_spss: %{},
      cached_ppss: %{},
      initial_spss: initial_parameters_to_list(opts.sps),
      initial_ppss: initial_parameters_to_list(opts.pps),
      input_parsed_stream_type: nil,
      input_raw_stream_type: nil,
      output_parsed_stream_type: output_parsed_stream_type
    }

    {[], state}
  end

  @impl true
  def handle_stream_format(:input, stream_format, ctx, state) do
    {mode, input_raw_stream_type} =
      case stream_format do
        %RemoteStream{type: :bytestream} ->
          {:bytestream, :annexb}

        %H264{alignment: alignment, stream_type: stream_type} ->
          {alignment, stream_type}

        %H264.RemoteStream{alignment: alignment, stream_type: stream_type} ->
          {alignment, stream_type}
      end

    mode =
      case mode do
        :au -> :au_aligned
        :nalu -> :nalu_aligned
        :bytestream -> :bytestream
      end

    first_received_stream_format? = is_nil(ctx.pads.input.stream_format)

    state =
      if first_received_stream_format? do
        input_parsed_stream_type = parse_raw_stream_type(input_raw_stream_type)

        %{
          state
          | mode: mode,
            nalu_splitter: NALuSplitter.new(input_parsed_stream_type),
            nalu_parser:
              NALuParser.new(input_parsed_stream_type, state.output_parsed_stream_type),
            input_parsed_stream_type: input_parsed_stream_type
        }
      else
        if not stream_types_compatible?(input_raw_stream_type, state.input_parsed_stream_type),
          do: raise("stream type cannot be changed during stream")

        if mode != state.mode, do: raise("mode cannot be changed during stream")

        state
      end

    {incoming_spss, incoming_ppss} =
      case input_raw_stream_type do
        :annexb ->
          if first_received_stream_format?,
            do: {state.initial_spss, state.initial_ppss},
            else: {[], []}

        {_avc, dcr} ->
          {:ok, %{spss: dcr_spss, ppss: dcr_ppss}} = DecoderConfigurationRecord.parse(dcr)

          new_spss =
            Enum.filter(dcr_spss, fn
              sps -> sps not in Enum.map(state.cached_spss, fn {_id, nalu} -> nalu.payload end)
            end)

          new_ppss =
            Enum.filter(dcr_ppss, fn
              sps -> sps not in Enum.map(state.cached_ppss, fn {_id, nalu} -> nalu.payload end)
            end)

          {new_spss, new_ppss}
      end

    process_stream_format_parameter_sets(incoming_spss, incoming_ppss, ctx, state)
  end

  @impl true
  def handle_process(:input, %Membrane.Buffer{} = buffer, ctx, state) do
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

    {actions, state} = prepare_actions_for_aus(access_units, ctx, state, buffer.pts, buffer.dts)

    state = %{
      state
      | nalu_splitter: nalu_splitter,
        nalu_parser: nalu_parser,
        au_splitter: au_splitter
    }

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

    {actions, state} = prepare_actions_for_aus(maybe_improper_aus, ctx, state)
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

  @spec initial_parameters_to_list(binary() | [binary()]) :: [binary()]
  defp initial_parameters_to_list(pss) do
    case pss do
      <<>> -> []
      ps when is_binary(ps) -> [ps]
      pss -> pss
    end
  end

  @spec stream_types_compatible?(
          raw_stream_type() | parsed_stream_type(),
          raw_stream_type() | parsed_stream_type()
        ) :: boolean()
  defp stream_types_compatible?(:annexb, :annexb), do: true
  defp stream_types_compatible?({avc, _}, {avc, _}), do: true
  defp stream_types_compatible?(_, _), do: false

  @spec process_stream_format_parameter_sets([binary()], [binary()], CallbackContext.t(), state()) ::
          {[Action.t()], state()}
  defp process_stream_format_parameter_sets(
         spss,
         ppss,
         ctx,
         %{output_parsed_stream_type: {:avc1, _}} = state
       ) do
    nalu_parser = state.nalu_parser

    {parsed_spss, nalu_parser} = parse_nalus(spss, nalu_parser)
    {parsed_ppss, nalu_parser} = parse_nalus(ppss, nalu_parser)

    state = %{state | nalu_parser: nalu_parser}

    new_spss = Enum.filter(parsed_spss, &(&1 not in Map.values(state.cached_spss)))
    new_ppss = Enum.filter(parsed_ppss, &(&1 not in Map.values(state.cached_ppss)))

    process_new_parameter_sets(new_spss, new_ppss, ctx, state)
  end

  defp process_stream_format_parameter_sets(spss, ppss, _ctx, state) do
    frame_prefix = generate_frame_prefix(spss ++ ppss, state.input_parsed_stream_type)
    {[], %{state | frame_prefix: frame_prefix}}
  end

  @spec parse_nalus([binary()], NALuParser.t()) ::
          {[NALu.t()], NALuParser.t()}
  defp parse_nalus(nalus, nalu_parser) do
    Enum.map_reduce(nalus, nalu_parser, fn nalu, nalu_parser ->
      NALuParser.parse(nalu, nalu_parser, false)
    end)
  end

  @spec unparse_nalus([NALu.t()], parsed_stream_type()) :: [binary()]
  defp unparse_nalus(nalus, :annexb) do
    Enum.map(nalus, fn nalu ->
      case nalu.payload do
        <<0, 0, 1, rest::binary>> -> rest
        <<0, 0, 0, 1, rest::binary>> -> rest
      end
    end)
  end

  defp unparse_nalus(nalus, {_avc, nalu_length_size}) do
    Enum.map(nalus, fn nalu ->
      <<_nalu_length::integer-size(nalu_length_size)-unit(8), rest::binary>> = nalu.payload
      rest
    end)
  end

  @spec parse_raw_stream_type(raw_stream_type()) :: parsed_stream_type()
  defp parse_raw_stream_type(:annexb), do: :annexb

  defp parse_raw_stream_type({avc, dcr}) do
    {:ok, %{nalu_length_size: nalu_length_size}} = DecoderConfigurationRecord.parse(dcr)
    {avc, nalu_length_size}
  end

  @spec generate_frame_prefix([binary()], parsed_stream_type()) :: binary()
  defp generate_frame_prefix(nalus, :annexb) do
    Enum.join([<<>> | nalus], @annexb_prefix_code)
  end

  defp generate_frame_prefix(nalus, {_avc, nalu_length_size}) do
    Enum.map(nalus, fn nalu ->
      <<byte_size(nalu)::integer-size(nalu_length_size)-unit(8), nalu::binary>>
    end)
    |> Enum.join()
  end

  @spec prepare_actions_for_aus(
          [AUSplitter.access_unit()],
          CallbackContext.t(),
          state(),
          Membrane.Time.t(),
          Membrane.Time.t()
        ) :: callback_return()
  defp prepare_actions_for_aus(aus, ctx, state, buffer_pts \\ nil, buffer_dts \\ nil) do
    #    IO.inspect(aus, label: "AUs")
    {actions, state} =
      Enum.flat_map_reduce(aus, state, fn au, state ->
        {au, stream_format_actions, state} = process_au_parameter_sets(au, ctx, state)

        {pts, dts} = prepare_timestamps(buffer_pts, buffer_dts, state)

        state = %{state | au_counter: state.au_counter + 1}

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
            [buffer: {:output, wrap_into_buffer(au, pts, dts, state.output_alignment)}]
          end

        {stream_format_actions ++ buffers_actions, state}
      end)

    state =
      if state.mode == :nalu_aligned and state.previous_timestamps != {buffer_pts, buffer_dts} do
        %{state | previous_timestamps: {buffer_pts, buffer_dts}}
      else
        state
      end

    {actions, state}
  end

  @spec process_new_parameter_sets([NALu.t()], [NALu.t()], CallbackContext.t(), state()) ::
          {[Action.t()], state()}
  defp process_new_parameter_sets(new_spss, new_ppss, context, state) do
    updated_spss =
      new_spss
      |> Enum.map(&{&1.parsed_fields.seq_parameter_set_id, &1})
      |> Map.new()
      |> then(&Map.merge(state.cached_spss, &1))

    updated_ppss =
      new_ppss
      |> Enum.map(&{&1.parsed_fields.pic_parameter_set_id, &1})
      |> Map.new()
      |> then(&Map.merge(state.cached_ppss, &1))

    state = %{state | cached_spss: updated_spss, cached_ppss: updated_ppss}

    latest_sps = List.last(new_spss)

    last_sent_stream_format = context.pads.output.stream_format

    output_raw_stream_type =
      case state.output_parsed_stream_type do
        :annexb ->
          :annexb

        {avc, nalu_length_size} ->
          {avc,
           DecoderConfigurationRecord.generate(
             Map.values(updated_spss) |> unparse_nalus(state.output_parsed_stream_type),
             Map.values(updated_ppss) |> unparse_nalus(state.output_parsed_stream_type),
             {avc, nalu_length_size}
           )}
      end

    format =
      cond do
        is_nil(latest_sps) and is_nil(last_sent_stream_format) ->
          nil

        is_nil(latest_sps) and not is_nil(last_sent_stream_format) ->
          %{last_sent_stream_format | stream_type: output_raw_stream_type}

        not is_nil(latest_sps) ->
          Format.from_sps(latest_sps, output_raw_stream_type,
            framerate: state.framerate,
            output_alignment: state.output_alignment
          )
      end

    if last_sent_stream_format != format do
      {[stream_format: {:output, format}], %{state | profile: format.profile}}
    else
      {[], state}
    end
  end

  @spec process_au_parameter_sets(AUSplitter.access_unit(), CallbackContext.t(), state()) ::
          {AUSplitter.access_unit(), [Action.t()], state()}
  defp process_au_parameter_sets(au, context, state) do
    au_spss = Enum.filter(au, &(&1.type == :sps))
    au_ppss = Enum.filter(au, &(&1.type == :pps))

    #    IO.inspect(au_spss, label: "au_spss")

    {stream_format_actions, state} = process_new_parameter_sets(au_spss, au_ppss, context, state)

    #    IO.inspect(stream_format_actions, label: "stream_format_actions")
    au =
      case state.output_parsed_stream_type do
        {:avc1, _nalu_length_size} ->
          remove_parameter_sets(au)

        _stream_type ->
          maybe_add_parameter_sets(au, state)
          |> delete_duplicate_parameter_sets()
      end

    {au, stream_format_actions, state}
  end

  defp prepare_timestamps(_buffer_pts, _buffer_dts, state)
       when state.mode == :bytestream do
    cond do
      state.framerate == nil or state.profile == nil ->
        {nil, nil}

      h264_profile_tsgen_supported?(state.profile) ->
        frame_order_number = state.au_counter

        generate_ts_with_constant_framerate(
          state.framerate,
          frame_order_number,
          frame_order_number
        )

      true ->
        raise("Timestamp generation for H264 profile `#{inspect(state.profile)}` is unsupported")
    end
  end

  @spec prepare_timestamps(Membrane.Time.t(), Membrane.Time.t(), state()) ::
          {Membrane.Time.t(), Membrane.Time.t()}
  defp prepare_timestamps(buffer_pts, buffer_dts, state)
       when state.mode == :nalu_aligned do
    if state.previous_timestamps == {nil, nil} do
      {buffer_pts, buffer_dts}
    else
      state.previous_timestamps
    end
  end

  defp prepare_timestamps(buffer_pts, buffer_dts, state)
       when state.mode == :au_aligned do
    {buffer_pts, buffer_dts}
  end

  defp maybe_add_parameter_sets(au, %{repeat_parameter_sets?: false}), do: au

  defp maybe_add_parameter_sets(au, state) do
    if idr_au?(au),
      do: Map.values(state.cached_spss) ++ Map.values(state.cached_ppss) ++ au,
      else: au
  end

  defp delete_duplicate_parameter_sets(au) do
    if idr_au?(au), do: Enum.uniq(au), else: au
  end

  defp remove_parameter_sets(au) do
    Enum.reject(au, &(&1.type in [:sps, :pps]))
  end

  defp idr_au?(au), do: :idr in Enum.map(au, & &1.type)

  defp wrap_into_buffer(access_unit, pts, dts, :au) do
    metadata = prepare_au_metadata(access_unit)

    buffer =
      Enum.reduce(access_unit, <<>>, fn nalu, acc ->
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
