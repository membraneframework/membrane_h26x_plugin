defmodule Membrane.H26x.Parser.Utils do
  @moduledoc false

  # The Membrane-aware (but codec-agnostic) driver of the parser, shared by the
  # `Membrane.H264.Parser` and `Membrane.H265.Parser` elements.
  #
  # It owns the whole element orchestration - the `Membrane.H26x.Parser.Core` lifecycle,
  # parameter-set caching, stream-structure/mode tracking, action and buffer building - and
  # delegates the handful of codec-specific decisions to a `codec` map (see `t:codec/0`)
  # injected by the elements, so it never dispatches back into them and needs no behaviour.

  alias Membrane.Buffer
  alias Membrane.H26x.{NALu, NALuParser}
  alias Membrane.H26x.Parser.Core

  @typedoc """
  Codec-specific configuration injected by an element: the codec's pure decision functions
  plus its NALu parser module and the metadata key used on output buffers.
  """
  @type codec :: %{
          parse_raw_input_stream_structure: (Membrane.StreamFormat.t() ->
                                               {:bytestream | :nalu | :au,
                                                Core.stream_structure(), [binary()]}),
          remove_parameter_sets_from_stream?: (Core.stream_structure() -> boolean()),
          generate_stream_format: ([NALu.t()], Membrane.StreamFormat.t() | nil, state() ->
                                     Membrane.StreamFormat.t() | nil),
          get_parameter_sets: (Core.access_unit() -> [NALu.t()]),
          keyframe?: (Core.access_unit() -> boolean()),
          nalu_parser_mod: module(),
          au_splitter_mod: module(),
          au_timestamp_generator_mod: module(),
          metadata_key: atom()
        }

  @typedoc """
  Element state driven by this module.
  """
  @type state :: %{
          :core => Core.t() | nil,
          :codec => codec(),
          :generate_best_effort_timestamps => false | map(),
          :output_alignment => :au | :nalu,
          :skip_until_keyframe => boolean(),
          :repeat_parameter_sets => boolean(),
          :initial_parameter_sets => [binary()],
          :mode => Core.mode() | nil,
          :input_stream_structure => Core.stream_structure() | nil,
          :output_stream_structure => Core.stream_structure() | nil,
          :framerate => term() | nil,
          :cached_parameter_sets => [NALu.t()],
          :frame_prefix => binary()
        }

  @type action :: Membrane.Element.Action.t()

  @doc """
  Builds the initial element state.

  Expects the codec config and the element options (`output_alignment`,
  `skip_until_keyframe`, `repeat_parameter_sets`, `initial_parameter_sets`,
  `output_stream_structure`, `generate_best_effort_timestamps`). The `Core` itself is
  created once the first stream format reveals the input structure and mode.
  """
  @spec init_state(codec(), keyword()) :: state()
  def init_state(codec, opts) do
    %{
      core: nil,
      codec: codec,
      generate_best_effort_timestamps: opts[:generate_best_effort_timestamps],
      output_alignment: opts[:output_alignment],
      skip_until_keyframe: opts[:skip_until_keyframe],
      repeat_parameter_sets: opts[:repeat_parameter_sets],
      initial_parameter_sets: opts[:initial_parameter_sets],
      mode: nil,
      input_stream_structure: nil,
      output_stream_structure: opts[:output_stream_structure],
      framerate: framerate(opts[:generate_best_effort_timestamps]),
      cached_parameter_sets: [],
      frame_prefix: <<>>
    }
  end

  @doc """
  Handles a new input stream format.
  """
  @spec handle_stream_format(Membrane.StreamFormat.t(), map(), state()) :: {[action()], state()}
  def handle_stream_format(stream_format, ctx, state) do
    {alignment, input_stream_structure, parameter_sets} =
      state.codec.parse_raw_input_stream_structure.(stream_format)

    mode = mode_from_alignment(alignment)
    is_first_received_stream_format = is_nil(ctx.pads.output.stream_format)

    {au_actions, state} =
      cond do
        is_first_received_stream_format ->
          {[], start_core(state, stream_format, mode, input_stream_structure)}

        not input_stream_structure_change_allowed?(
          input_stream_structure,
          state.input_stream_structure
        ) ->
          raise "stream structure cannot be fundamentally changed during stream"

        mode != state.mode ->
          {actions, state} = flush_and_process(ctx, state)
          {actions, %{state | core: Core.set_mode(state.core, mode), mode: mode}}

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

    {au_actions, prepend_parameter_sets(state, incoming_parameter_sets)}
  end

  @doc """
  Handles an input buffer.
  """
  @spec handle_buffer(Buffer.t(), map(), state()) :: {[action()], state()}
  def handle_buffer(buffer, ctx, state) do
    {payload, state} =
      case state.frame_prefix do
        <<>> -> {buffer.payload, state}
        prefix -> {prefix <> buffer.payload, %{state | frame_prefix: <<>>}}
      end

    {access_units, core} = Core.push(state.core, payload, {buffer.pts, buffer.dts})
    process_access_units(access_units, ctx, %{state | core: core})
  end

  @doc """
  Handles end of stream, flushing any buffered data and emitting the `:end_of_stream`
  action.
  """
  @spec handle_end_of_stream(map(), state()) :: {[action()], state()}
  def handle_end_of_stream(ctx, state) do
    {actions, state} = flush_and_process(ctx, state)
    actions = if stream_format_sent?(actions, ctx), do: actions, else: []
    {actions ++ [end_of_stream: :output], state}
  end

  @spec start_core(state(), Membrane.StreamFormat.t(), Core.mode(), Core.stream_structure()) ::
          state()
  defp start_core(state, stream_format, mode, input_stream_structure) do
    core =
      Core.new(%{
        input_stream_structure: input_stream_structure,
        mode: mode,
        nalu_parser_mod: state.codec.nalu_parser_mod,
        au_splitter_mod: state.codec.au_splitter_mod,
        au_timestamp_generator_mod: state.codec.au_timestamp_generator_mod,
        generate_best_effort_timestamps: state.generate_best_effort_timestamps
      })

    %{
      state
      | core: core,
        mode: mode,
        input_stream_structure: input_stream_structure,
        output_stream_structure: state.output_stream_structure || input_stream_structure,
        framerate: Map.get(stream_format, :framerate) || state.framerate
    }
  end

  @spec flush_and_process(map(), state()) :: {[action()], state()}
  defp flush_and_process(ctx, state) do
    {access_units, core} = Core.flush(state.core)
    process_access_units(access_units, ctx, %{state | core: core})
  end

  @spec process_access_units([Core.access_unit()], map(), state()) :: {[action()], state()}
  defp process_access_units(access_units, ctx, state) do
    Enum.flat_map_reduce(access_units, state, fn au, state ->
      {au, stream_format_actions, state} = handle_au_parameter_sets(au, ctx, state)
      {buffer_actions, state} = prepare_buffer_actions(au, state)
      {stream_format_actions ++ buffer_actions, state}
    end)
  end

  defp handle_au_parameter_sets(au, ctx, state) do
    parameter_sets = state.codec.get_parameter_sets.(au)
    {stream_format_actions, state} = cache_and_maybe_stream_format(parameter_sets, ctx, state)

    au =
      finalize_au_parameter_sets(au, parameter_sets, state.cached_parameter_sets,
        strip?: state.codec.remove_parameter_sets_from_stream?.(state.output_stream_structure),
        repeat?: state.repeat_parameter_sets,
        keyframe?: state.codec.keyframe?.(au)
      )

    {au, stream_format_actions, state}
  end

  # Caches the given parameter sets and emits a new stream format if they changed it.
  defp cache_and_maybe_stream_format(parameter_sets, ctx, state) do
    last_sent_stream_format = ctx.pads.output.stream_format
    state = %{state | cached_parameter_sets: cache(state.cached_parameter_sets, parameter_sets)}

    stream_format_candidate =
      state.codec.generate_stream_format.(parameter_sets, last_sent_stream_format, state)

    if stream_format_candidate in [last_sent_stream_format, nil] do
      {[], state}
    else
      {[stream_format: {:output, stream_format_candidate}], state}
    end
  end

  # Reconciles an access unit's parameter sets for output: they are either removed (when
  # the output carries them out of band) or, on a keyframe, repeated and de-duplicated.
  defp finalize_au_parameter_sets(au, parameter_sets, cached, opts) do
    cond do
      opts[:strip?] ->
        Enum.filter(au, &(&1 not in parameter_sets))

      opts[:keyframe?] ->
        Enum.uniq_by(if(opts[:repeat?], do: cached ++ au, else: au), & &1.payload)

      true ->
        au
    end
  end

  # Stores the incoming parameter sets as a prefix prepended to the next processed buffer.
  # They are then parsed and cached (and stripped/repeated) as any other in-stream NALu.
  defp prepend_parameter_sets(state, []), do: state

  defp prepend_parameter_sets(state, parameter_sets) do
    prefix = NALuParser.prefix_nalus_payloads(parameter_sets, state.input_stream_structure)
    %{state | frame_prefix: state.frame_prefix <> prefix}
  end

  defp incoming_parameter_sets(:annexb, _parameter_sets, true, state),
    do: state.initial_parameter_sets

  defp incoming_parameter_sets(:annexb, _parameter_sets, false, _state), do: []

  defp incoming_parameter_sets(_structure, parameter_sets, _is_first, state),
    do: parameter_sets -- Enum.map(state.cached_parameter_sets, & &1.payload)

  defp cache(cached_parameter_sets, new_parameter_sets) do
    cached_payloads = Enum.map(cached_parameter_sets, & &1.payload)
    cached_parameter_sets ++ Enum.filter(new_parameter_sets, &(&1.payload not in cached_payloads))
  end

  defp input_stream_structure_change_allowed?(:annexb, :annexb), do: true
  defp input_stream_structure_change_allowed?({tag, _new_len}, {tag, _old_len}), do: true
  defp input_stream_structure_change_allowed?(_new, _old), do: false

  defp mode_from_alignment(:bytestream), do: :bytestream
  defp mode_from_alignment(:nalu), do: :nalu_aligned
  defp mode_from_alignment(:au), do: :au_aligned

  defp framerate(false), do: nil
  defp framerate(%{framerate: framerate}), do: framerate

  # Turns an access unit into output buffer actions, updating the skip-until-keyframe flag.
  #
  # The access unit is dropped (no actions) when it contains an invalid NALu, when it has
  # no VCL NALu, or while still skipping until the first keyframe. Otherwise it is wrapped
  # into a buffer (`:au` alignment) or a list of buffers (`:nalu` alignment).
  @spec prepare_buffer_actions(Core.access_unit(), state()) :: {[action()], state()}
  defp prepare_buffer_actions(au, state) do
    keyframe? = state.codec.keyframe?.(au)
    nalu_parser_mod = state.codec.nalu_parser_mod

    {should_forward?, skip_until_keyframe?} =
      should_forward_au(au, keyframe?, state.skip_until_keyframe, nalu_parser_mod)

    state = %{state | skip_until_keyframe: skip_until_keyframe?}

    if should_forward? do
      {pts, dts} = nalu_parser_mod.get_first_vcl_nalu(au).timestamps

      buffers =
        wrap_into_buffer(
          au,
          pts,
          dts,
          keyframe?,
          state.output_alignment,
          state.output_stream_structure,
          state.codec.metadata_key
        )

      {[buffer: {:output, buffers}], state}
    else
      {[], state}
    end
  end

  defp should_forward_au(au, keyframe?, skip_until_keyframe?, nalu_parser_mod) do
    with true <- Enum.all?(au, &(&1.status == :valid)),
         true <- nalu_parser_mod.get_first_vcl_nalu(au) != nil do
      skip_until_keyframe? = skip_until_keyframe? and not keyframe?
      {not skip_until_keyframe?, skip_until_keyframe?}
    else
      false -> {false, skip_until_keyframe?}
    end
  end

  defp wrap_into_buffer(au, pts, dts, keyframe?, :au, output_stream_structure, metadata_key) do
    payload =
      Enum.reduce(au, <<>>, fn nalu, acc ->
        acc <> NALuParser.get_prefixed_nalu_payload(nalu, output_stream_structure)
      end)

    %Buffer{
      payload: payload,
      metadata: prepare_au_metadata(au, keyframe?, metadata_key),
      pts: pts,
      dts: dts
    }
  end

  defp wrap_into_buffer(au, pts, dts, keyframe?, :nalu, output_stream_structure, metadata_key) do
    au
    |> Enum.zip(prepare_nalus_metadata(au, keyframe?, metadata_key))
    |> Enum.map(fn {nalu, metadata} ->
      %Buffer{
        payload: NALuParser.get_prefixed_nalu_payload(nalu, output_stream_structure),
        metadata: metadata,
        pts: pts,
        dts: dts
      }
    end)
  end

  # Tells whether a stream format has been sent - either previously (present in `ctx`) or
  # as one of the given actions.
  defp stream_format_sent?(actions, %{pads: %{output: %{stream_format: nil}}}),
    do: Enum.any?(actions, &match?({:stream_format, _stream_format}, &1))

  defp stream_format_sent?(_actions, _ctx), do: true

  defp prepare_au_metadata(nalus, keyframe?, metadata_key) do
    nalus =
      nalus
      |> Enum.with_index()
      |> Enum.map(fn {nalu, i} ->
        %{metadata: Map.put(%{}, metadata_key, %{type: nalu.type})}
        |> Bunch.then_if(
          i == 0,
          &put_in(&1, [:metadata, metadata_key, :new_access_unit], %{key_frame?: keyframe?})
        )
        |> Bunch.then_if(
          i == length(nalus) - 1,
          &put_in(&1, [:metadata, metadata_key, :end_access_unit], true)
        )
      end)

    %{metadata_key => %{key_frame?: keyframe?, nalus: nalus}}
  end

  defp prepare_nalus_metadata(nalus, keyframe?, metadata_key) do
    nalus
    |> Enum.with_index()
    |> Enum.map(fn {nalu, i} ->
      Map.put(%{}, metadata_key, %{type: nalu.type})
      |> Bunch.then_if(
        i == 0,
        &put_in(&1, [metadata_key, :new_access_unit], %{key_frame?: keyframe?})
      )
      |> Bunch.then_if(
        i == length(nalus) - 1,
        &put_in(&1, [metadata_key, :end_access_unit], true)
      )
    end)
  end
end
