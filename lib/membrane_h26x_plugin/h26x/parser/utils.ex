defmodule Membrane.H26x.Parser.Utils do
  @moduledoc false

  # The Membrane-aware (but codec-agnostic) driver of the parser, shared by the
  # `Membrane.H264.Parser` and `Membrane.H265.Parser` elements.
  #
  # It owns the whole element orchestration - handling stream formats, buffers and end of
  # stream, building actions and buffers, and threading the `Membrane.H26x.Parser.Core`
  # state. The codec-specific decisions are injected by the elements as a `codec` map
  # (see `t:codec/0`) held in the element state, so this module never dispatches back into
  # the element and needs no behaviour.

  alias Membrane.Buffer
  alias Membrane.H26x.{NALu, NALuParser}
  alias Membrane.H26x.Parser.Core

  @typedoc """
  Codec-specific configuration injected by an element.

  It bundles the codec's pure decision functions together with the codec's NALu parser
  module and the metadata key used on output buffers.
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
          metadata_key: atom()
        }

  @typedoc """
  Element state driven by this module.
  """
  @type state :: %{
          :core => Core.t(),
          :codec => codec(),
          :output_alignment => :au | :nalu,
          :skip_until_keyframe => boolean(),
          :repeat_parameter_sets => boolean(),
          :initial_parameter_sets => [binary()],
          optional(atom()) => term()
        }

  @type action :: Membrane.Element.Action.t()

  @doc """
  Builds the initial element state around a fresh `Core` and the given codec config.
  """
  @spec init_state(Core.t(), codec(),
          output_alignment: :au | :nalu,
          skip_until_keyframe: boolean(),
          repeat_parameter_sets: boolean(),
          initial_parameter_sets: [binary()]
        ) :: state()
  def init_state(core, codec, opts) do
    %{
      core: core,
      codec: codec,
      output_alignment: opts[:output_alignment],
      skip_until_keyframe: opts[:skip_until_keyframe],
      repeat_parameter_sets: opts[:repeat_parameter_sets],
      initial_parameter_sets: opts[:initial_parameter_sets]
    }
  end

  @doc """
  Handles a new input stream format.
  """
  @spec handle_stream_format(Membrane.StreamFormat.t(), map(), state()) :: {[action()], state()}
  def handle_stream_format(stream_format, ctx, state) do
    {alignment, input_stream_structure, parameter_sets} =
      state.codec.parse_raw_input_stream_structure.(stream_format)

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

  @doc """
  Handles an input buffer.
  """
  @spec handle_buffer(Buffer.t(), map(), state()) :: {[action()], state()}
  def handle_buffer(buffer, ctx, state) do
    {access_units, core} =
      Core.process_buffer(state.core, buffer.payload, {buffer.pts, buffer.dts})

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

    {stream_format_actions, state} =
      cache_and_maybe_stream_format(parameter_sets, ctx.pads.output.stream_format, state)

    au =
      Core.finalize_au_parameter_sets(state.core, au, parameter_sets,
        strip?:
          state.codec.remove_parameter_sets_from_stream?.(
            Core.output_stream_structure(state.core)
          ),
        repeat?: state.repeat_parameter_sets,
        keyframe?: state.codec.keyframe?.(au)
      )

    {au, stream_format_actions, state}
  end

  defp handle_stream_format_parameter_sets(parameter_sets, last_sent_stream_format, state) do
    if state.codec.remove_parameter_sets_from_stream?.(Core.output_stream_structure(state.core)) do
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
      state.codec.generate_stream_format.(parameter_sets, last_sent_stream_format, state)

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
          Core.output_stream_structure(state.core),
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
