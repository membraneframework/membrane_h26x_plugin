defmodule Membrane.H2645.Parser do
  @moduledoc false

  require Membrane.Logger
  require Membrane.H264.NALuTypes, as: AVCNALuTypes

  alias Membrane.H264.DecoderConfigurationRecord, as: AVCDecoderConfigurationRecord

  alias Membrane.H265.DecoderConfigurationRecord, as: HEVCDecoderConfigurationRecord
  alias Membrane.H265.NALuTypes, as: HEVCNALuTypes

  alias Membrane.H26x.{AUSplitter, AUTimestampGenerator, NALu, NALuParser, NALuSplitter}
  alias Membrane.{Buffer, H264, H265, RemoteStream}

  @typedoc """
  Type referencing `Membrane.H264.stream_structure` type, in case of `:avc1` and `:avc3`
  stream structure, it contains an information about the size of each NALU's prefix describing
  their length.
  """
  @type stream_structure ::
          :annexb
          | {:avc1 | :avc3, nalu_length_size :: pos_integer()}
          | {:hvc1 | :hev1, nalu_length_size :: pos_integer()}

  @type encoding :: :h264 | :h265

  @typep raw_stream_structure :: H264.stream_structure() | H265.stream_structure()
  @typep state :: Membrane.Element.state()
  @typep stream_format :: Membrane.StreamFormat.t()
  @typep access_unit :: [NALu.t()]
  @typep callback_return :: Membrane.Element.Base.callback_return()

  @nalu_length_size 4

  @spec new(encoding(), map(), module()) :: state()
  def new(encoding, opts, au_splitter) do
    output_stream_structure =
      case opts.output_stream_structure do
        :avc3 -> {:avc3, @nalu_length_size}
        :avc1 -> {:avc1, @nalu_length_size}
        :hvc1 -> {:hvc1, @nalu_length_size}
        :hev1 -> {:hev1, @nalu_length_size}
        stream_structure -> stream_structure
      end

    {au_timestamp_generator, framerate} =
      get_timestamp_generator(encoding, opts.generate_best_effort_timestamps)

    %{
      encoding: encoding,
      nalu_splitter: nil,
      nalu_parser: nil,
      au_splitter: au_splitter.new(),
      au_splitter_module: au_splitter,
      au_timestamp_generator: au_timestamp_generator,
      framerate: framerate,
      mode: nil,
      profile: nil,
      previous_buffer_timestamps: nil,
      output_alignment: opts.output_alignment,
      frame_prefix: <<>>,
      skip_until_keyframe: opts.skip_until_keyframe,
      repeat_parameter_sets: opts.repeat_parameter_sets,
      cached_vpss: %{},
      cached_spss: %{},
      cached_ppss: %{},
      initial_vpss: Map.get(opts, :vpss, []),
      initial_spss: opts.spss,
      initial_ppss: opts.ppss,
      input_stream_structure: nil,
      output_stream_structure: output_stream_structure
    }
  end

  @spec handle_stream_format(state(), stream_format(), stream_format() | nil) ::
          {stream_format() | nil, state()}
  def handle_stream_format(state, stream_format, old_stream_format) do
    {alignment, input_raw_stream_structure} =
      case stream_format do
        %RemoteStream{type: :bytestream} ->
          {:bytestream, :annexb}

        %mod{alignment: alignment, stream_structure: stream_structure} when mod in [H264, H265] ->
          {alignment, stream_structure}
      end

    is_first_received_stream_format = is_nil(old_stream_format)

    mode = get_mode_from_alignment(alignment)

    input_stream_structure =
      parse_raw_stream_structure(state.encoding, input_raw_stream_structure)

    state =
      cond do
        is_first_received_stream_format ->
          output_stream_structure =
            if is_nil(state.output_stream_structure),
              do: input_stream_structure,
              else: state.output_stream_structure

          %{
            state
            | mode: mode,
              nalu_splitter: NALuSplitter.new(input_stream_structure),
              nalu_parser: NALuParser.new(state.encoding, input_stream_structure),
              input_stream_structure: input_stream_structure,
              output_stream_structure: output_stream_structure,
              framerate: Map.get(stream_format, :framerate) || state.framerate
          }

        not is_input_stream_structure_change_allowed?(
          input_stream_structure,
          state.input_stream_structure
        ) ->
          raise "stream structure cannot be fundamentally changed during stream"

        mode != state.mode ->
          raise "mode cannot be changed during stream"

        true ->
          state
      end

    {incoming_vpss, incoming_spss, incoming_ppss} =
      get_stream_format_parameter_sets(
        input_raw_stream_structure,
        is_first_received_stream_format,
        state
      )

    process_stream_format_parameter_sets(
      incoming_vpss,
      incoming_spss,
      incoming_ppss,
      old_stream_format,
      state
    )
  end

  @spec handle_process(state(), Buffer.t(), nil | stream_format()) :: callback_return()
  def handle_process(state, %Membrane.Buffer{} = buffer, old_stream_format) do
    {payload, state} =
      case state.frame_prefix do
        <<>> -> {buffer.payload, state}
        prefix -> {prefix <> buffer.payload, %{state | frame_prefix: <<>>}}
      end

    is_nalu_aligned = state.mode != :bytestream

    {nalus_payloads, nalu_splitter} =
      NALuSplitter.split(payload, is_nalu_aligned, state.nalu_splitter)

    timestamps = if state.mode == :bytestream, do: {nil, nil}, else: {buffer.pts, buffer.dts}
    {nalus, nalu_parser} = NALuParser.parse_nalus(nalus_payloads, timestamps, state.nalu_parser)
    is_au_aligned = state.mode == :au_aligned

    {access_units, au_splitter} =
      state.au_splitter_module.split(nalus, is_au_aligned, state.au_splitter)

    {actions, state} = prepare_actions_for_aus(access_units, old_stream_format, state)

    state = %{
      state
      | nalu_splitter: nalu_splitter,
        nalu_parser: nalu_parser,
        au_splitter: au_splitter
    }

    {actions, state}
  end

  @spec handle_end_of_stream(state(), nil | stream_format()) :: callback_return()
  def handle_end_of_stream(state, old_stream_format) when state.mode != :au_aligned do
    {last_nalu_payload, nalu_splitter} = NALuSplitter.split(<<>>, true, state.nalu_splitter)
    {last_nalu, nalu_parser} = NALuParser.parse_nalus(last_nalu_payload, state.nalu_parser)

    {aus, au_splitter} =
      state.au_splitter_module.split(last_nalu, true, state.au_splitter)

    {actions, state} = prepare_actions_for_aus(aus, old_stream_format, state)

    state = %{
      state
      | nalu_splitter: nalu_splitter,
        nalu_parser: nalu_parser,
        au_splitter: au_splitter
    }

    {actions, state}
  end

  def handle_end_of_stream(state, _old_stream_format) do
    {[], state}
  end

  @spec get_timestamp_generator(encoding(), false | map()) :: term()
  defp get_timestamp_generator(_encoding, false), do: {nil, nil}

  defp get_timestamp_generator(encoding, generate_best_effort_timestamps),
    do:
      {AUTimestampGenerator.new(encoding, generate_best_effort_timestamps),
       generate_best_effort_timestamps.framerate}

  @spec get_mode_from_alignment(:au | :nalu | :bytestream) ::
          :au_aligned | :nalu_aligned | :bytestream
  defp get_mode_from_alignment(alignment) do
    case alignment do
      :au -> :au_aligned
      :nalu -> :nalu_aligned
      :bytestream -> :bytestream
    end
  end

  @spec get_stream_format_parameter_sets(raw_stream_structure(), boolean(), state()) ::
          {[binary()], [binary()], [binary()]}
  defp get_stream_format_parameter_sets(
         {_avc_or_hevc, dcr},
         _is_first_received_stream_format,
         state
       ) do
    dcr_module =
      case state.encoding do
        :h264 -> AVCDecoderConfigurationRecord
        :h265 -> HEVCDecoderConfigurationRecord
      end

    dcr = dcr_module.parse(dcr)

    new_uncached_vpss =
      Map.get(dcr, :vpss, []) -- Enum.map(state.cached_spss, fn {_id, ps} -> ps.payload end)

    new_uncached_spss =
      Map.get(dcr, :spss, []) -- Enum.map(state.cached_spss, fn {_id, ps} -> ps.payload end)

    new_uncached_ppss =
      Map.get(dcr, :ppss, []) -- Enum.map(state.cached_ppss, fn {_id, ps} -> ps.payload end)

    {new_uncached_vpss, new_uncached_spss, new_uncached_ppss}
  end

  defp get_stream_format_parameter_sets(:annexb, is_first_received_stream_format, state) do
    if is_first_received_stream_format,
      do: {state.initial_vpss, state.initial_spss, state.initial_ppss},
      else: {[], [], []}
  end

  @spec process_stream_format_parameter_sets(
          [binary()],
          [binary()],
          [binary()],
          stream_format() | nil,
          state()
        ) ::
          {stream_format() | nil, state()}
  defp process_stream_format_parameter_sets(
         new_vpss,
         new_spss,
         new_ppss,
         stream_format,
         %{output_stream_structure: {format, _}} = state
       )
       when format in [:avc1, :hvc1] do
    {parsed_new_uncached_vpss, nalu_parser} =
      NALuParser.parse_nalus(new_vpss, {nil, nil}, false, state.nalu_parser)

    {parsed_new_uncached_spss, nalu_parser} =
      NALuParser.parse_nalus(new_spss, {nil, nil}, false, nalu_parser)

    {parsed_new_uncached_ppss, nalu_parser} =
      NALuParser.parse_nalus(new_ppss, {nil, nil}, false, nalu_parser)

    state = %{state | nalu_parser: nalu_parser}

    process_new_parameter_sets(
      parsed_new_uncached_vpss,
      parsed_new_uncached_spss,
      parsed_new_uncached_ppss,
      stream_format,
      state
    )
  end

  defp process_stream_format_parameter_sets(vpss, spss, ppss, _ctx, state) do
    frame_prefix =
      NALuParser.prefix_nalus_payloads(vpss ++ spss ++ ppss, state.input_stream_structure)

    {nil, %{state | frame_prefix: frame_prefix}}
  end

  @spec is_input_stream_structure_change_allowed?(
          raw_stream_structure() | stream_structure(),
          raw_stream_structure() | stream_structure()
        ) :: boolean()
  defp is_input_stream_structure_change_allowed?(:annexb, :annexb), do: true
  defp is_input_stream_structure_change_allowed?({avc_or_hevc, _}, {avc_or_hevc, _}), do: true

  defp is_input_stream_structure_change_allowed?(_stream_structure1, _stream_structure2),
    do: false

  @spec parse_raw_stream_structure(encoding(), raw_stream_structure()) :: stream_structure()
  defp parse_raw_stream_structure(_encoding, :annexb), do: :annexb

  defp parse_raw_stream_structure(:h264, {avc, dcr}) do
    %{nalu_length_size: nalu_length_size} = AVCDecoderConfigurationRecord.parse(dcr)
    {avc, nalu_length_size}
  end

  defp parse_raw_stream_structure(:h265, {hevc, dcr}) do
    %{nalu_length_size: nalu_length_size} = HEVCDecoderConfigurationRecord.parse(dcr)
    {hevc, nalu_length_size}
  end

  @spec skip_au?(AUSplitter.access_unit(), state()) :: {boolean(), state()}
  defp skip_au?(au, state) do
    has_seen_keyframe? =
      Enum.all?(au, &(&1.status == :valid)) and key_frame?(state.encoding, au)

    state = %{
      state
      | skip_until_keyframe: state.skip_until_keyframe and not has_seen_keyframe?
    }

    {Enum.any?(au, &(&1.status == :error)) or state.skip_until_keyframe, state}
  end

  @spec prepare_actions_for_aus([access_unit()], nil | stream_format(), state()) ::
          callback_return()
  defp prepare_actions_for_aus(aus, stream_format, state) do
    Enum.flat_map_reduce(aus, state, fn au, state ->
      {au, stream_format, state} = process_au_parameter_sets(au, stream_format, state)
      {{pts, dts}, state} = prepare_timestamps(au, state)

      {should_skip_au, state} = skip_au?(au, state)

      buffers_actions =
        if should_skip_au do
          []
        else
          buffers =
            wrap_into_buffer(au, pts, dts, state.output_alignment, state)

          [buffer: {:output, buffers}]
        end

      stream_format_action =
        case stream_format do
          nil -> []
          stream_format -> [stream_format: {:output, stream_format}]
        end

      {stream_format_action ++ buffers_actions, state}
    end)
  end

  @spec process_new_parameter_sets(
          [NALu.t()],
          [NALu.t()],
          [NALu.t()],
          stream_format() | nil,
          state()
        ) ::
          {stream_format() | nil, state()}
  defp process_new_parameter_sets(new_vpss, new_spss, new_ppss, last_sent_stream_format, state) do
    updated_cached_vpss =
      merge_parameter_sets(new_vpss, state.cached_vpss, :video_parameter_set_id)

    updated_cached_spss = merge_parameter_sets(new_spss, state.cached_spss, :seq_parameter_set_id)
    updated_cached_ppss = merge_parameter_sets(new_ppss, state.cached_ppss, :pic_parameter_set_id)

    state = %{
      state
      | cached_vpss: updated_cached_vpss,
        cached_spss: updated_cached_spss,
        cached_ppss: updated_cached_ppss
    }

    latest_sps = List.last(new_spss)

    output_raw_stream_structure =
      case state.output_stream_structure do
        :annexb ->
          :annexb

        {avc, _nalu_length_size} = output_stream_structure when avc in [:avc1, :avc3] ->
          {avc,
           AVCDecoderConfigurationRecord.generate(
             Enum.map(updated_cached_spss, fn {_id, sps} -> sps.payload end),
             Enum.map(updated_cached_ppss, fn {_id, pps} -> pps.payload end),
             output_stream_structure
           )}

        {hevc, _nalu_length_size} = output_stream_structure when hevc in [:hvc1, :hev1] ->
          {hevc,
           HEVCDecoderConfigurationRecord.generate(
             Enum.map(updated_cached_vpss, fn {_id, vps} -> vps end),
             Enum.map(updated_cached_spss, fn {_id, sps} -> sps end),
             Enum.map(updated_cached_ppss, fn {_id, pps} -> pps end),
             output_stream_structure
           )}
      end

    stream_format_candidate =
      case {latest_sps, last_sent_stream_format} do
        {nil, nil} ->
          nil

        {nil, last_sent_stream_format} ->
          %{last_sent_stream_format | stream_structure: output_raw_stream_structure}

        {latest_sps, _last_sent_stream_format} ->
          generate_stream_format(latest_sps, output_raw_stream_structure, state)
      end

    if stream_format_candidate in [last_sent_stream_format, nil] do
      {nil, state}
    else
      {stream_format_candidate, %{state | profile: stream_format_candidate.profile}}
    end
  end

  @spec generate_stream_format(NALu.t(), raw_stream_structure(), state()) :: stream_format()
  defp generate_stream_format(sps, output_raw_stream_structure, state) do
    sps = sps.parsed_fields

    format_module =
      case state.encoding do
        :h264 -> H264
        :h265 -> H265
      end

    stream_format = %{
      width: sps.width,
      height: sps.height,
      profile: sps.profile,
      framerate: state.framerate,
      alignment: state.output_alignment,
      nalu_in_metadata?: true,
      stream_structure: output_raw_stream_structure
    }

    struct!(format_module, stream_format)
  end

  @spec merge_parameter_sets([NALu.t()], %{non_neg_integer() => NALu.t()}, atom()) ::
          %{non_neg_integer() => NALu.t()}
  defp merge_parameter_sets(new_parameter_sets, cached_parameter_sets, id_key) do
    new_parameter_sets
    |> Enum.map(&{&1.parsed_fields[id_key], &1})
    |> Map.new()
    |> then(&Map.merge(cached_parameter_sets, &1))
  end

  @spec process_au_parameter_sets(access_unit(), nil | stream_format(), state()) ::
          {access_unit(), stream_format() | nil, state()}
  defp process_au_parameter_sets(au, old_stream_format, state) do
    au_vpss = Enum.filter(au, &(&1.type == :vps))
    au_spss = Enum.filter(au, &(&1.type == :sps))
    au_ppss = Enum.filter(au, &(&1.type == :pps))

    {stream_format, state} =
      process_new_parameter_sets(au_vpss, au_spss, au_ppss, old_stream_format, state)

    au =
      case state.output_stream_structure do
        {format, _nalu_length_size} when format in [:avc1, :hvc1] ->
          remove_parameter_sets(au)

        _stream_structure ->
          maybe_add_parameter_sets(au, state)
          |> delete_duplicate_parameter_sets(state)
      end

    {au, stream_format, state}
  end

  @spec prepare_timestamps(access_unit(), state()) ::
          {{Membrane.Time.t(), Membrane.Time.t()}, state()}
  defp prepare_timestamps(au, state) do
    if state.mode == :bytestream and state.au_timestamp_generator do
      {timestamps, timestamp_generator} =
        AUTimestampGenerator.generate_ts_with_constant_framerate(
          au,
          state.au_timestamp_generator
        )

      {timestamps, %{state | au_timestamp_generator: timestamp_generator}}
    else
      timestamps =
        case state.encoding do
          :h264 -> Enum.find(au, &AVCNALuTypes.is_vcl_nalu_type(&1.type)).timestamps
          :h265 -> Enum.find(au, &(&1.type in HEVCNALuTypes.vcl_nalu_types())).timestamps
        end

      {timestamps, state}
    end
  end

  @spec maybe_add_parameter_sets(access_unit(), state()) :: access_unit()
  defp maybe_add_parameter_sets(au, %{repeat_parameter_sets: false}), do: au

  defp maybe_add_parameter_sets(au, state) do
    if key_frame?(state.encoding, au),
      do: Map.values(state.cached_spss) ++ Map.values(state.cached_ppss) ++ au,
      else: au
  end

  @spec delete_duplicate_parameter_sets(access_unit(), state()) :: access_unit()
  defp delete_duplicate_parameter_sets(au, state) do
    if key_frame?(state.encoding, au), do: Enum.uniq(au), else: au
  end

  @spec remove_parameter_sets(access_unit()) :: access_unit()
  defp remove_parameter_sets(au) do
    Enum.reject(au, &(&1.type in [:vps, :sps, :pps]))
  end

  @spec key_frame?(encoding(), AUSplitter.access_unit()) :: boolean()
  defp key_frame?(:h264, au), do: :idr in Enum.map(au, & &1.type)
  defp key_frame?(:h265, au), do: Enum.any?(au, &(&1.type in HEVCNALuTypes.irap_nalus()))

  @spec wrap_into_buffer(
          access_unit(),
          Membrane.Time.t(),
          Membrane.Time.t(),
          :au | :nalu,
          state()
        ) :: Buffer.t() | [Buffer.t()]
  defp wrap_into_buffer(access_unit, pts, dts, :au, state) do
    Enum.reduce(access_unit, <<>>, fn nalu, acc ->
      acc <> NALuParser.get_prefixed_nalu_payload(nalu, state.output_stream_structure)
    end)
    |> then(fn payload ->
      %Buffer{payload: payload, metadata: prepare_au_metadata(access_unit, state), pts: pts, dts: dts}
    end)
  end

  defp wrap_into_buffer(access_unit, pts, dts, :nalu, state) do
    access_unit
    |> Enum.zip(prepare_nalus_metadata(access_unit, state))
    |> Enum.map(fn {nalu, metadata} ->
      %Buffer{
        payload: NALuParser.get_prefixed_nalu_payload(nalu, state.output_stream_structure),
        metadata: metadata,
        pts: pts,
        dts: dts
      }
    end)
  end

  @spec prepare_au_metadata(access_unit(), state()) :: Buffer.metadata()
  defp prepare_au_metadata(nalus, %{encoding: encoding}) do
    is_keyframe? = key_frame?(encoding, nalus)

    nalus =
      nalus
      |> Enum.with_index()
      |> Enum.map(fn {nalu, i} ->
        %{metadata: Map.put(%{}, encoding, %{type: nalu.type})}
        |> Bunch.then_if(
          i == 0,
          &put_in(&1, [:metadata, encoding, :new_access_unit], %{key_frame?: is_keyframe?})
        )
        |> Bunch.then_if(
          i == length(nalus) - 1,
          &put_in(&1, [:metadata, encoding, :end_access_unit], true)
        )
      end)

    %{encoding => %{key_frame?: is_keyframe?, nalus: nalus}}
  end

  @spec prepare_nalus_metadata(AUSplitter.access_unit(), state()) :: [Buffer.metadata()]
  defp prepare_nalus_metadata(nalus, %{encoding: encoding}) do
    is_keyframe? = key_frame?(encoding, nalus)

    Enum.with_index(nalus)
    |> Enum.map(fn {nalu, i} ->
      Map.put(%{}, encoding, %{type: nalu.type})
      |> Bunch.then_if(
        i == 0,
        &put_in(&1, [encoding, :new_access_unit], %{key_frame?: is_keyframe?})
      )
      |> Bunch.then_if(i == length(nalus) - 1, &put_in(&1, [encoding, :end_access_unit], true))
    end)
  end
end
