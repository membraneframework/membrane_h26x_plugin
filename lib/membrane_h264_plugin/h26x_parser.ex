defmodule Membrane.H26x.Parser do
  @moduledoc false

  alias Membrane.Buffer
  alias Membrane.H26x.{AUSplitter, NALuSplitter}

  @typedoc """
  A type of a module implementing `Membrane.H26x.Parser` behaviour.
  """
  @type t :: module()

  @typedoc """
  Stream structure of the NALUs. In case it's not `:annexb` format, it contains an information
  about the size of each NALU's prefix describing their length.
  """
  @type stream_structure ::
          Membrane.H264.Parser.stream_structure() | Membrane.H265.Parser.stream_structure()

  @type callback_context :: Membrane.Element.CallbackContext.t()
  @type action :: Membrane.Element.Action.t()
  @type parameter_sets :: tuple()
  @type stream_format :: Membrane.StreamFormat.t()
  @type state :: Membrane.Element.state()
  @type alignment :: :bytestream | :nalu | :au
  @type raw_stream_structure ::
          :annexb | {codec_tag :: atom(), decoder_configuration_record :: binary()}

  @typep callback_return :: Membrane.Element.Base.callback_return()

  @doc """
  Invoked each time a new stream format arrives. It should return a tuple of 3
  elements: the alignment of the NALUs, the stream structure and the parameter sets.
  """
  @callback parse_raw_input_stream_structure(stream_format()) ::
              {alignment(), stream_structure(), parameter_sets()}

  @doc """
  Invoked for each parsed access unit and when a new stream format arrives.

  Indicate whether parameter sets should be removed from the stream.
  """
  @callback remove_parameter_sets_from_stream?(stream_structure()) :: boolean()

  @doc """
  Invoked each time a new stream format or new parameter sets arrives.

  The callback receives the new parameter sets (retrieved from the new stream format or from the access units),
  the last sent stream format and the state of the parser.

  Returns the new stream format or `nil`.
  """
  @callback generate_stream_format(
              parameter_sets(),
              last_sent_stream_format :: stream_format(),
              state()
            ) :: stream_format() | nil

  @doc """
  Invoked for each parsed access unit.
  """
  @callback get_parameter_sets(AUSplitter.access_unit()) :: parameter_sets()

  @doc """
  Invoked for each parsed access unit.

  Returns `true` if the access unit is a keyframe.
  """
  @callback keyframe?(AUSplitter.access_unit()) :: boolean()

  @spec handle_init(map(), map(), t(), module(), module(), module(), atom()) ::
          callback_return()
  def handle_init(
        _ctx,
        opts,
        parser_module,
        au_timestamp_generator_mod,
        nalu_parser,
        au_splitter,
        metadata_key
      ) do
    {au_timestamp_generator, framerate} =
      get_timestamp_generator(opts.generate_best_effort_timestamps, au_timestamp_generator_mod)

    state =
      %{
        nalu_splitter: nil,
        nalu_parser: nil,
        au_splitter: au_splitter.new(),
        au_timestamp_generator: au_timestamp_generator,
        framerate: framerate,
        mode: nil,
        profile: nil,
        previous_buffer_timestamps: nil,
        output_alignment: opts.output_alignment,
        frame_prefix: <<>>,
        skip_until_keyframe: opts.skip_until_keyframe,
        repeat_parameter_sets: opts.repeat_parameter_sets,
        initial_parameter_sets: opts.initial_parameter_sets,
        cached_parameter_sets: empty_parameter_sets(opts.initial_parameter_sets),
        input_stream_structure: nil,
        output_stream_structure: opts.output_stream_structure,
        au_timestamp_generator_mod: au_timestamp_generator_mod,
        nalu_parser_mod: nalu_parser,
        au_splitter_mod: au_splitter,
        metadata_key: metadata_key,
        module: parser_module
      }

    {[], state}
  end

  @spec handle_stream_format(stream_format(), callback_context(), state()) :: callback_return()
  def handle_stream_format(stream_format, ctx, state) do
    {alignment, input_stream_structure, parameter_sets} =
      state.module.parse_raw_input_stream_structure(stream_format)

    is_first_received_stream_format = is_nil(ctx.pads.output.stream_format)

    mode = get_mode_from_alignment(alignment)

    {access_units_actions, state} =
      cond do
        is_first_received_stream_format ->
          output_stream_structure =
            if is_nil(state.output_stream_structure),
              do: input_stream_structure,
              else: state.output_stream_structure

          {[],
           %{
             state
             | mode: mode,
               nalu_splitter: NALuSplitter.new(input_stream_structure),
               nalu_parser: state.nalu_parser_mod.new(input_stream_structure),
               input_stream_structure: input_stream_structure,
               output_stream_structure: output_stream_structure,
               framerate: Map.get(stream_format, :framerate) || state.framerate
           }}

        not is_input_stream_structure_change_allowed?(
          input_stream_structure,
          state.input_stream_structure
        ) ->
          raise "stream structure cannot be fundamentally changed during stream"

        mode != state.mode ->
          {access_units, state} = clean_state(state)
          access_unit_actions = prepare_actions_for_aus(access_units, ctx, state)
          state = %{state | mode: mode}
          {access_unit_actions, state}

        true ->
          {[], state}
      end

    incoming_parameter_sets =
      get_stream_format_parameter_sets(
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

    {access_units_actions ++ stream_format_actions, state}
  end

  @spec handle_buffer(Buffer.t(), callback_context(), state()) ::
          {[AUSplitter.access_unit()], state()}
  def handle_buffer(%Buffer{} = buffer, ctx, state) do
    {payload, state} =
      case state.frame_prefix do
        <<>> -> {buffer.payload, state}
        prefix -> {prefix <> buffer.payload, %{state | frame_prefix: <<>>}}
      end

    is_nalu_aligned = state.mode != :bytestream

    {nalus_payloads, nalu_splitter} =
      NALuSplitter.split(payload, is_nalu_aligned, state.nalu_splitter)

    timestamps = {buffer.pts, buffer.dts}

    {nalus, nalu_parser} =
      state.nalu_parser_mod.parse_nalus(nalus_payloads, timestamps, state.nalu_parser)

    is_au_aligned = state.mode == :au_aligned

    {access_units, au_splitter} =
      state.au_splitter_mod.split(nalus, is_au_aligned, state.au_splitter)

    state = %{
      state
      | nalu_splitter: nalu_splitter,
        nalu_parser: nalu_parser,
        au_splitter: au_splitter
    }

    prepare_actions_for_aus(access_units, ctx, state)
  end

  @spec handle_end_of_stream(callback_context(), state()) :: callback_return()
  def handle_end_of_stream(ctx, state) do
    {nalus_payloads, nalu_splitter} = NALuSplitter.split(<<>>, true, state.nalu_splitter)
    {nalus, nalu_parser} = state.nalu_parser_mod.parse_nalus(nalus_payloads, state.nalu_parser)
    {access_units, au_splitter} = state.au_splitter_mod.split(nalus, true, state.au_splitter)

    state = %{
      state
      | nalu_splitter: nalu_splitter,
        nalu_parser: nalu_parser,
        au_splitter: au_splitter
    }

    {actions, state} = prepare_actions_for_aus(access_units, ctx, state)
    actions = if stream_format_sent?(actions, ctx), do: actions, else: []
    {actions ++ [end_of_stream: :output], state}
  end

  @spec process_stream_format_parameter_sets(parameter_sets(), stream_format(), state()) ::
          callback_return()
  defp process_stream_format_parameter_sets(parameter_sets, stream_format, state) do
    if state.module.remove_parameter_sets_from_stream?(state.output_stream_structure) do
      {parsed_parameter_sets, nalu_parser} =
        Enum.map_reduce(Tuple.to_list(parameter_sets), state.nalu_parser, fn ps, nalu_parser ->
          state.nalu_parser_mod.parse_nalus(ps, {nil, nil}, false, nalu_parser)
        end)

      state = %{state | nalu_parser: nalu_parser}

      process_new_parameter_sets(
        List.to_tuple(parsed_parameter_sets),
        stream_format,
        state
      )
    else
      frame_prefix =
        state.nalu_parser_mod.prefix_nalus_payloads(
          flatten_parameter_sets(parameter_sets),
          state.input_stream_structure
        )

      {[], %{state | frame_prefix: frame_prefix}}
    end
  end

  @spec get_stream_format_parameter_sets(stream_structure(), parameter_sets(), boolean(), state()) ::
          parameter_sets()
  def get_stream_format_parameter_sets(:annexb, _pss, is_first_received_stream_format, state) do
    if is_first_received_stream_format,
      do: state.initial_parameter_sets,
      else: empty_parameter_sets(state.initial_parameter_sets)
  end

  def get_stream_format_parameter_sets(
        _stream_structure,
        parameter_sets,
        _is_first_received_stream_format,
        state
      ) do
    Tuple.to_list(parameter_sets)
    |> Enum.zip(Tuple.to_list(state.cached_parameter_sets))
    |> Enum.map(fn {new_ps, cached_ps} -> new_ps -- Enum.map(cached_ps, & &1.payload) end)
    |> List.to_tuple()
  end

  @spec get_mode_from_alignment(:au | :nalu | :bytestream) ::
          :au_aligned | :nalu_aligned | :bytestream
  def get_mode_from_alignment(alignment) do
    case alignment do
      :au -> :au_aligned
      :nalu -> :nalu_aligned
      :bytestream -> :bytestream
    end
  end

  @spec is_input_stream_structure_change_allowed?(stream_structure(), stream_structure()) ::
          boolean()
  def is_input_stream_structure_change_allowed?(:annexb, :annexb), do: true
  def is_input_stream_structure_change_allowed?({codec_tag, _}, {codec_tag, _}), do: true

  def is_input_stream_structure_change_allowed?(_stream_structure1, _stream_structure2),
    do: false

  @spec merge_parameter_sets(parameter_sets(), parameter_sets()) :: parameter_sets()
  def merge_parameter_sets(new_parameter_sets, cached_parameter_sets) do
    Tuple.to_list(cached_parameter_sets)
    |> Enum.zip(Tuple.to_list(new_parameter_sets))
    |> Enum.map(fn {cached_pss, new_pss} ->
      payloads = Enum.map(cached_pss, & &1.payload)
      cached_pss ++ Enum.filter(new_pss, &(&1.payload not in payloads))
    end)
    |> List.to_tuple()
  end

  @spec prepare_actions_for_aus(
          [AUSplitter.access_unit()],
          callback_context(),
          state()
        ) ::
          callback_return()
  defp prepare_actions_for_aus(aus, ctx, state) do
    Enum.flat_map_reduce(aus, state, fn au, state ->
      {au, stream_format, state} = process_au_parameter_sets(au, ctx, state)
      {buffers_actions, state} = prepare_actions_for_au(au, state.module.keyframe?(au), state)
      {stream_format ++ buffers_actions, state}
    end)
  end

  @spec process_au_parameter_sets(
          AUSplitter.access_unit(),
          callback_context(),
          state()
        ) ::
          {AUSplitter.access_unit(), [action()], state()}
  defp process_au_parameter_sets(au, ctx, state) do
    old_stream_format = ctx.pads.output.stream_format
    parameter_sets = state.module.get_parameter_sets(au)

    {stream_format, state} =
      process_new_parameter_sets(parameter_sets, old_stream_format, state)

    au =
      if state.module.remove_parameter_sets_from_stream?(state.output_stream_structure) do
        Enum.filter(au, &(&1 not in flatten_parameter_sets(parameter_sets)))
      else
        maybe_add_parameter_sets(au, state)
        |> delete_duplicate_parameter_sets(state)
      end

    {au, stream_format, state}
  end

  @spec delete_duplicate_parameter_sets(AUSplitter.access_unit(), state()) ::
          AUSplitter.access_unit()
  defp delete_duplicate_parameter_sets(au, state) do
    if state.module.keyframe?(au), do: Enum.uniq_by(au, & &1.payload), else: au
  end

  @spec maybe_add_parameter_sets(AUSplitter.access_unit(), state()) ::
          AUSplitter.access_unit()
  defp maybe_add_parameter_sets(au, %{repeat_parameter_sets: false}), do: au

  defp maybe_add_parameter_sets(au, state) do
    if state.module.keyframe?(au),
      do: flatten_parameter_sets(state.cached_parameter_sets) ++ au,
      else: au
  end

  @spec prepare_actions_for_au(AUSplitter.access_unit(), boolean(), state()) :: callback_return()
  def prepare_actions_for_au(au, keyframe?, state) do
    {{pts, dts}, state} = prepare_timestamps(au, state)
    {should_skip_au, state} = skip_au?(au, keyframe?, state)

    buffers_actions =
      if should_skip_au do
        []
      else
        buffers = wrap_into_buffer(au, pts, dts, keyframe?, state)
        [buffer: {:output, buffers}]
      end

    {buffers_actions, state}
  end

  @spec flatten_parameter_sets(parameter_sets()) :: list()
  defp flatten_parameter_sets(parameter_sets) do
    Tuple.to_list(parameter_sets) |> List.flatten()
  end

  @spec stream_format_sent?([action()], callback_context()) :: boolean()
  defp stream_format_sent?(actions, %{pads: %{output: %{stream_format: nil}}}),
    do: Enum.any?(actions, &match?({:stream_format, _stream_format}, &1))

  defp stream_format_sent?(_actions, _ctx), do: true

  @spec clean_state(state()) :: {[AUSplitter.access_unit()], state()}
  def clean_state(state) do
    {nalus_payloads, nalu_splitter} = NALuSplitter.split(<<>>, true, state.nalu_splitter)
    {nalus, nalu_parser} = state.nalu_parser_mod.parse_nalus(nalus_payloads, state.nalu_parser)
    {access_units, au_splitter} = state.au_splitter_mod.split(nalus, true, state.au_splitter)

    {access_units,
     %{
       state
       | nalu_splitter: nalu_splitter,
         nalu_parser: nalu_parser,
         au_splitter: au_splitter
     }}
  end

  @spec prepare_timestamps(AUSplitter.access_unit(), state()) ::
          {{Membrane.Time.t(), Membrane.Time.t()}, state()}
  defp prepare_timestamps(au, state) do
    if state.mode == :bytestream and state.au_timestamp_generator do
      {timestamps, timestamp_generator} =
        state.au_timestamp_generator_mod.generate_ts_with_constant_framerate(
          au,
          state.au_timestamp_generator
        )

      {timestamps, %{state | au_timestamp_generator: timestamp_generator}}
    else
      {List.last(au).timestamps, state}
    end
  end

  @spec skip_au?(AUSplitter.access_unit(), boolean(), state()) :: {boolean(), state()}
  defp skip_au?(au, keyframe?, state) do
    has_seen_keyframe? = keyframe? and Enum.all?(au, &(&1.status == :valid))

    state = %{
      state
      | skip_until_keyframe: state.skip_until_keyframe and not has_seen_keyframe?
    }

    {Enum.any?(au, &(&1.status == :error)) or state.skip_until_keyframe, state}
  end

  @spec wrap_into_buffer(
          AUSplitter.access_unit(),
          Membrane.Time.t(),
          Membrane.Time.t(),
          boolean(),
          state()
        ) :: Buffer.t() | [Buffer.t()]
  defp wrap_into_buffer(access_unit, pts, dts, key_frame?, %{output_alignment: :au} = state) do
    Enum.reduce(access_unit, <<>>, fn nalu, acc ->
      acc <> state.nalu_parser_mod.get_prefixed_nalu_payload(nalu, state.output_stream_structure)
    end)
    |> then(fn payload ->
      %Buffer{
        payload: payload,
        metadata: prepare_au_metadata(access_unit, key_frame?, state.metadata_key),
        pts: pts,
        dts: dts
      }
    end)
  end

  defp wrap_into_buffer(access_unit, pts, dts, key_frame?, %{output_alignment: :nalu} = state) do
    access_unit
    |> Enum.zip(prepare_nalus_metadata(access_unit, key_frame?, state.metadata_key))
    |> Enum.map(fn {nalu, metadata} ->
      %Buffer{
        payload:
          state.nalu_parser_mod.get_prefixed_nalu_payload(nalu, state.output_stream_structure),
        metadata: metadata,
        pts: pts,
        dts: dts
      }
    end)
  end

  @spec prepare_au_metadata(AUSplitter.access_unit(), boolean(), atom()) :: Buffer.metadata()
  defp prepare_au_metadata(nalus, is_keyframe?, metadata_key) do
    nalus =
      nalus
      |> Enum.with_index()
      |> Enum.map(fn {nalu, i} ->
        %{metadata: Map.put(%{}, metadata_key, %{type: nalu.type})}
        |> Bunch.then_if(
          i == 0,
          &put_in(&1, [:metadata, metadata_key, :new_access_unit], %{
            key_frame?: is_keyframe?
          })
        )
        |> Bunch.then_if(
          i == length(nalus) - 1,
          &put_in(&1, [:metadata, metadata_key, :end_access_unit], true)
        )
      end)

    %{metadata_key => %{key_frame?: is_keyframe?, nalus: nalus}}
  end

  @spec prepare_nalus_metadata(AUSplitter.access_unit(), boolean(), atom()) :: [Buffer.metadata()]
  defp prepare_nalus_metadata(nalus, is_keyframe?, metadata_key) do
    Enum.with_index(nalus)
    |> Enum.map(fn {nalu, i} ->
      Map.put(%{}, metadata_key, %{type: nalu.type})
      |> Bunch.then_if(
        i == 0,
        &put_in(&1, [metadata_key, :new_access_unit], %{key_frame?: is_keyframe?})
      )
      |> Bunch.then_if(
        i == length(nalus) - 1,
        &put_in(&1, [metadata_key, :end_access_unit], true)
      )
    end)
  end

  @spec get_timestamp_generator(false | map(), module()) :: term()
  defp get_timestamp_generator(false, _au_timestamp_generator), do: {nil, nil}

  defp get_timestamp_generator(generate_best_effort_timestamps, au_timestamp_generator) do
    {au_timestamp_generator.new(generate_best_effort_timestamps),
     generate_best_effort_timestamps.framerate}
  end

  @spec empty_parameter_sets(parameter_sets()) :: parameter_sets()
  defp empty_parameter_sets(parameter_sets) do
    Enum.map(1..tuple_size(parameter_sets), fn _id -> [] end)
    |> List.to_tuple()
  end

  @spec process_new_parameter_sets(parameter_sets(), stream_format(), state()) ::
          callback_return()
  defp process_new_parameter_sets(parameter_sets, last_sent_stream_format, state) do
    updated_parameter_sets =
      merge_parameter_sets(parameter_sets, state.cached_parameter_sets)

    state = %{state | cached_parameter_sets: updated_parameter_sets}

    stream_format_candidate =
      state.module.generate_stream_format(parameter_sets, last_sent_stream_format, state)

    if stream_format_candidate in [last_sent_stream_format, nil] do
      {[], state}
    else
      {[stream_format: {:output, stream_format_candidate}],
       %{state | profile: stream_format_candidate.profile}}
    end
  end
end
