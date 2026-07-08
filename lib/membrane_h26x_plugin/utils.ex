defmodule Membrane.H26x.Utils do
  @moduledoc false

  # The Membrane-aware (but codec-agnostic) driver of the parser, shared by the
  # `Membrane.H264.Parser` and `Membrane.H265.Parser` elements.

  alias Membrane.Buffer
  alias Membrane.H26x.NALu
  alias Membrane.H26x.ParsingEngine

  @typedoc """
  Element state driven by this module.
  """
  @type state :: %{
          parsing_engine: ParsingEngine.t() | nil,
          codec: ParsingEngine.codec(),
          generate_best_effort_timestamps: false | map(),
          output_alignment: :au | :nalu,
          skip_until_keyframe: boolean(),
          repeat_parameter_sets: boolean(),
          initial_parameter_sets: [binary()],
          input_stream_structure: ParsingEngine.stream_structure() | nil,
          output_stream_structure: ParsingEngine.stream_structure() | nil,
          framerate: term() | nil,
          cached_parameter_sets: [NALu.t()]
        }

  @type action :: Membrane.Element.Action.t()

  @doc """
  Builds the initial element state.

  Expects the codec and the element options (`output_alignment`, `skip_until_keyframe`,
  `repeat_parameter_sets`, `initial_parameter_sets`, `output_stream_structure`,
  `generate_best_effort_timestamps`). The `ParsingEngine` itself is created once
  the first stream format reveals the input structure and alignment.
  """
  @spec init_state(ParsingEngine.codec(), keyword()) :: state()
  def init_state(codec, opts) do
    %{
      parsing_engine: nil,
      codec: codec,
      generate_best_effort_timestamps: opts[:generate_best_effort_timestamps],
      output_alignment: opts[:output_alignment],
      skip_until_keyframe: opts[:skip_until_keyframe],
      repeat_parameter_sets: opts[:repeat_parameter_sets],
      initial_parameter_sets: opts[:initial_parameter_sets],
      input_stream_structure: nil,
      output_stream_structure: opts[:output_stream_structure],
      framerate: framerate(opts[:generate_best_effort_timestamps]),
      cached_parameter_sets: []
    }
  end

  @doc """
  Handles a new input stream format.

  The element parses the raw stream format itself and passes the resulting input
  alignment, stream structure and parameter sets (as raw payloads) along with the
  stream's framerate (or `nil`).
  """
  @spec handle_stream_format(
          {ParsingEngine.input_alignment(), ParsingEngine.stream_structure(), [binary()]},
          term() | nil,
          map(),
          state()
        ) :: {[action()], state()}
  def handle_stream_format(
        {alignment, input_stream_structure, parameter_sets},
        framerate,
        ctx,
        state
      ) do
    is_first_received_stream_format = is_nil(ctx.pads.output.stream_format)

    {au_actions, state} =
      cond do
        is_first_received_stream_format ->
          {[], start_parsing_engine(state, framerate, alignment, input_stream_structure)}

        not input_stream_structure_change_allowed?(
          input_stream_structure,
          state.input_stream_structure
        ) ->
          raise "stream structure cannot be fundamentally changed during stream"

        alignment != state.parsing_engine.input_alignment ->
          {actions, state} = flush_and_process(ctx, state)

          {actions,
           %{
             state
             | parsing_engine: ParsingEngine.set_input_alignment(state.parsing_engine, alignment)
           }}

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
    {access_units, parsing_engine} =
      ParsingEngine.push(state.parsing_engine, buffer.payload, {buffer.pts, buffer.dts})

    process_access_units(access_units, ctx, %{state | parsing_engine: parsing_engine})
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

  @spec start_parsing_engine(
          state(),
          term() | nil,
          ParsingEngine.input_alignment(),
          ParsingEngine.stream_structure()
        ) :: state()
  defp start_parsing_engine(state, framerate, input_alignment, input_stream_structure) do
    parsing_engine =
      ParsingEngine.new(%{
        codec: state.codec,
        input_stream_structure: input_stream_structure,
        input_alignment: input_alignment,
        generate_best_effort_timestamps: state.generate_best_effort_timestamps
      })

    %{
      state
      | parsing_engine: parsing_engine,
        input_stream_structure: input_stream_structure,
        output_stream_structure: state.output_stream_structure || input_stream_structure,
        framerate: framerate || state.framerate
    }
  end

  @spec flush_and_process(map(), state()) :: {[action()], state()}
  defp flush_and_process(ctx, state) do
    {access_units, parsing_engine} = ParsingEngine.flush(state.parsing_engine)
    process_access_units(access_units, ctx, %{state | parsing_engine: parsing_engine})
  end

  @spec process_access_units([ParsingEngine.access_unit()], map(), state()) ::
          {[action()], state()}
  defp process_access_units(access_units, ctx, state) do
    Enum.flat_map_reduce(access_units, state, fn au, state ->
      {au, stream_format_actions, state} = handle_au_parameter_sets(au, ctx, state)
      {buffer_actions, state} = prepare_buffer_actions(au, state)
      {stream_format_actions ++ buffer_actions, state}
    end)
  end

  defp handle_au_parameter_sets(au, ctx, state) do
    codec = state.codec
    parameter_sets = get_parameter_sets(au, codec)
    {stream_format_actions, state} = cache_and_maybe_stream_format(parameter_sets, ctx, state)

    au =
      finalize_au_parameter_sets(au, parameter_sets, state.cached_parameter_sets,
        strip?: strip_parameter_sets?(state.output_stream_structure, codec),
        repeat?: state.repeat_parameter_sets,
        keyframe?: keyframe?(au, codec)
      )

    {au, stream_format_actions, state}
  end

  defp keyframe?(au, codec), do: Enum.any?(au, &(&1.type in keyframe_nalu_types(codec)))

  defp get_parameter_sets(au, codec) do
    Enum.flat_map(parameter_set_nalu_types(codec), fn type ->
      Enum.filter(au, &(&1.type == type))
    end)
  end

  defp strip_parameter_sets?(:annexb, _codec), do: false

  defp strip_parameter_sets?({codec_tag, _nalu_length_size}, codec),
    do: codec_tag in out_of_band_parameter_sets_codec_tags(codec)

  defp stream_format_module(:h264), do: Membrane.H264
  defp stream_format_module(:h265), do: Membrane.H265

  defp keyframe_nalu_types(:h264), do: [:idr]

  defp keyframe_nalu_types(:h265),
    do: [:bla_w_lp, :bla_w_radl, :bla_n_lp, :idr_w_radl, :idr_n_lp, :cra]

  defp parameter_set_nalu_types(:h264), do: [:sps, :pps]
  defp parameter_set_nalu_types(:h265), do: [:vps, :sps, :pps]

  defp out_of_band_parameter_sets_codec_tags(:h264), do: [:avc1]
  defp out_of_band_parameter_sets_codec_tags(:h265), do: [:hvc1]

  defp cache_and_maybe_stream_format(parameter_sets, ctx, state) do
    last_sent_stream_format = ctx.pads.output.stream_format
    state = %{state | cached_parameter_sets: cache(state.cached_parameter_sets, parameter_sets)}

    stream_format_candidate =
      generate_stream_format(parameter_sets, last_sent_stream_format, state)

    if stream_format_candidate in [last_sent_stream_format, nil] do
      {[], state}
    else
      {[stream_format: {:output, stream_format_candidate}], state}
    end
  end

  defp generate_stream_format(new_parameter_sets, last_sent_stream_format, state) do
    latest_sps = new_parameter_sets |> Enum.filter(&(&1.type == :sps)) |> List.last()

    output_raw_stream_structure =
      case state.output_stream_structure do
        :annexb ->
          :annexb

        {codec_tag, _nalu_length_size} = structure ->
          dcr = ParsingEngine.generate_dcr(state.codec, state.cached_parameter_sets, structure)
          {codec_tag, dcr}
      end

    case {latest_sps, last_sent_stream_format} do
      {nil, nil} ->
        nil

      {nil, last_sent_stream_format} ->
        %{last_sent_stream_format | stream_structure: output_raw_stream_structure}

      {latest_sps, _last_sent_stream_format} ->
        sps = latest_sps.parsed_fields

        struct!(stream_format_module(state.codec),
          width: sps.width,
          height: sps.height,
          profile: sps.profile,
          framerate: state.framerate,
          alignment: state.output_alignment,
          nalu_in_metadata?: true,
          stream_structure: output_raw_stream_structure
        )
    end
  end

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

  defp prepend_parameter_sets(state, parameter_sets) do
    %{
      state
      | parsing_engine: ParsingEngine.prepend_parameter_sets(state.parsing_engine, parameter_sets)
    }
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

  defp framerate(false), do: nil
  defp framerate(%{framerate: framerate}), do: framerate

  @spec prepare_buffer_actions(ParsingEngine.access_unit(), state()) :: {[action()], state()}
  defp prepare_buffer_actions(au, state) do
    codec = state.codec
    keyframe? = keyframe?(au, codec)
    nalu_parser_mod = state.parsing_engine.nalu_parser_mod

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
          _metadata_key = codec
        )

      {[buffer: {:output, buffers}], state}
    else
      {[], state}
    end
  end

  defp should_forward_au(au, keyframe?, skip_until_keyframe?, nalu_parser_mod) do
    if Enum.all?(au, &(&1.status == :valid)) and nalu_parser_mod.get_first_vcl_nalu(au) != nil do
      skip_until_keyframe? = skip_until_keyframe? and not keyframe?
      {not skip_until_keyframe?, skip_until_keyframe?}
    else
      {false, skip_until_keyframe?}
    end
  end

  defp wrap_into_buffer(au, pts, dts, keyframe?, :au, output_stream_structure, metadata_key) do
    payload =
      Enum.map_join(
        au,
        <<>>,
        &ParsingEngine.get_prefixed_nalu_payload(&1, output_stream_structure)
      )

    %Buffer{
      payload: payload,
      metadata: prepare_metadata(:au, au, keyframe?, metadata_key),
      pts: pts,
      dts: dts
    }
  end

  defp wrap_into_buffer(au, pts, dts, keyframe?, :nalu, output_stream_structure, metadata_key) do
    au
    |> Enum.zip(prepare_metadata(:nalu, au, keyframe?, metadata_key))
    |> Enum.map(fn {nalu, metadata} ->
      %Buffer{
        payload: ParsingEngine.get_prefixed_nalu_payload(nalu, output_stream_structure),
        metadata: metadata,
        pts: pts,
        dts: dts
      }
    end)
  end

  defp stream_format_sent?(actions, %{pads: %{output: %{stream_format: nil}}}),
    do: Enum.any?(actions, &match?({:stream_format, _stream_format}, &1))

  defp stream_format_sent?(_actions, _ctx), do: true

  defp prepare_metadata(:au, nalus, keyframe?, metadata_key) do
    nalus =
      prepare_metadata(:nalu, nalus, keyframe?, metadata_key)
      |> Enum.map(&%{metadata: &1})

    %{metadata_key => %{key_frame?: keyframe?, nalus: nalus}}
  end

  defp prepare_metadata(:nalu, nalus, keyframe?, metadata_key) do
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
