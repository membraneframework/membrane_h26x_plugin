defmodule Membrane.H26x.Utils do
  @moduledoc false

  # The Membrane-aware (but codec-agnostic) driver of the parser, shared by the
  # `Membrane.H264.Parser` and `Membrane.H265.Parser` elements.

  alias Membrane.Buffer
  alias Membrane.H26x.{AccessUnit, ParsingEngine}

  @typedoc """
  Element state driven by this module.
  """
  @type state :: %{
          parsing_engine: ParsingEngine.t() | nil,
          codec: ParsingEngine.codec(),
          generate_best_effort_timestamps: false | map(),
          infer_dts_from_pts: boolean(),
          output_alignment: :au | :nalu,
          skip_until_keyframe: boolean(),
          repeat_parameter_sets: boolean(),
          initial_parameter_sets: [binary()],
          output_stream_structure: ParsingEngine.stream_structure() | nil,
          framerate: term() | nil,
          passthrough?: boolean()
        }

  @type action :: Membrane.Element.Action.t()

  @doc """
  Builds the initial element state.

  Expects the codec and the element options (`output_alignment`, `skip_until_keyframe`,
  `repeat_parameter_sets`, `initial_parameter_sets`, `output_stream_structure`,
  `generate_best_effort_timestamps`, `infer_dts_from_pts`). The `ParsingEngine` itself is created once
  the first stream format reveals the input structure and alignment.
  """
  @spec init_state(ParsingEngine.codec(), keyword()) :: state()
  def init_state(codec, opts) do
    %{
      parsing_engine: nil,
      codec: codec,
      generate_best_effort_timestamps: Keyword.get(opts, :generate_best_effort_timestamps, false),
      infer_dts_from_pts: Keyword.get(opts, :infer_dts_from_pts, false),
      output_alignment: opts[:output_alignment],
      skip_until_keyframe: opts[:skip_until_keyframe],
      repeat_parameter_sets: opts[:repeat_parameter_sets],
      initial_parameter_sets: opts[:initial_parameter_sets],
      output_stream_structure: opts[:output_stream_structure],
      framerate: framerate(opts[:generate_best_effort_timestamps]),
      passthrough?: false
    }
  end

  @doc """
  Handles a new input stream format.

  The element passes the stream format itself along with the input alignment and the
  raw input stream structure resolved from it.

  When the input is already parsed - AU-aligned, with the NALu metadata attached and
  in the structure the output is expected in - the element switches to a passthrough
  mode: the buffers are forwarded as they are, without being split or parsed again,
  and the input stream format is forwarded as the output one. See `passthrough?/2`
  for the exact conditions.
  """
  @spec handle_stream_format(
          struct(),
          {ParsingEngine.input_alignment(), ParsingEngine.input_stream_structure()},
          map(),
          state()
        ) :: {[action()], state()}
  def handle_stream_format(stream_format, {alignment, input_stream_structure}, ctx, state) do
    if passthrough?(stream_format, state) do
      enter_passthrough(stream_format, ctx, state)
    else
      state = %{state | passthrough?: false}

      if is_nil(state.parsing_engine) or is_nil(ctx.pads.output.stream_format) do
        {[],
         start_parsing_engine(
           state,
           Map.get(stream_format, :framerate),
           alignment,
           input_stream_structure
         )}
      else
        {events, parsing_engine} =
          ParsingEngine.reconfigure_input(state.parsing_engine, alignment, input_stream_structure)

        process_events(events, ctx, %{state | parsing_engine: parsing_engine})
      end
    end
  end

  @doc """
  Tells whether the buffers of the given input stream format can be forwarded without
  parsing.

  That is the case when the input is AU-aligned and carries the NALu metadata (so it
  has already been through a parser), the output is AU-aligned in the same stream
  structure (Annex B, or the input structure if none is configured and the input
  carries its parameter sets in-band) and no option requires the parameter sets to be
  inspected or altered.
  """
  @spec passthrough?(struct(), state()) :: boolean()
  def passthrough?(
        %{alignment: :au, nalu_in_metadata?: true, stream_structure: input_stream_structure},
        state
      ) do
    state.output_alignment == :au and not state.repeat_parameter_sets and
      state.initial_parameter_sets == [] and state.generate_best_effort_timestamps == false and
      passthrough_structure?(input_stream_structure, state.output_stream_structure)
  end

  def passthrough?(_stream_format, _state), do: false

  defp passthrough_structure?(:annexb, output) when output in [nil, :annexb], do: true
  defp passthrough_structure?({tag, _dcr}, nil) when tag in [:avc3, :hev1], do: true
  defp passthrough_structure?(_input, _output), do: false

  # the engine is dropped since the parameter sets forwarded meanwhile never reach it
  defp enter_passthrough(stream_format, ctx, state) do
    {actions, state} =
      if is_nil(state.parsing_engine) do
        {[], state}
      else
        {events, engine} = ParsingEngine.flush(state.parsing_engine)
        {actions, state} = process_events(events, ctx, %{state | parsing_engine: engine})
        {actions, %{state | parsing_engine: nil}}
      end

    stream_format_actions =
      if last_stream_format(actions, ctx) == stream_format,
        do: [],
        else: [stream_format: {:output, stream_format}]

    {actions ++ stream_format_actions, %{state | passthrough?: true}}
  end

  defp last_stream_format(actions, ctx) do
    Enum.reduce(actions, ctx.pads.output.stream_format, fn
      {:stream_format, {:output, stream_format}}, _last -> stream_format
      _action, last -> last
    end)
  end

  @doc """
  Handles an input buffer.
  """
  @spec handle_buffer(Buffer.t(), map(), state()) :: {[action()], state()}
  def handle_buffer(buffer, _ctx, %{passthrough?: true} = state) do
    skip_until_keyframe? =
      state.skip_until_keyframe and not keyframe_from_metadata(buffer.metadata, state.codec)

    state = %{state | skip_until_keyframe: skip_until_keyframe?}

    if skip_until_keyframe?,
      do: {[], state},
      else: {[buffer: {:output, buffer}], state}
  end

  def handle_buffer(buffer, ctx, state) do
    {events, parsing_engine} =
      ParsingEngine.push(state.parsing_engine, buffer.payload, {buffer.pts, buffer.dts})

    process_events(events, ctx, %{state | parsing_engine: parsing_engine})
  end

  @doc """
  Handles end of stream, flushing any buffered data and emitting the `:end_of_stream`
  action.
  """
  @spec handle_end_of_stream(map(), state()) :: {[action()], state()}
  def handle_end_of_stream(_ctx, %{passthrough?: true} = state) do
    {[end_of_stream: :output], state}
  end

  def handle_end_of_stream(ctx, state) do
    {events, parsing_engine} = ParsingEngine.flush(state.parsing_engine)
    {actions, state} = process_events(events, ctx, %{state | parsing_engine: parsing_engine})

    actions = if stream_format_sent?(actions, ctx), do: actions, else: []
    {actions ++ [end_of_stream: :output], state}
  end

  @spec start_parsing_engine(
          state(),
          term() | nil,
          ParsingEngine.input_alignment(),
          ParsingEngine.input_stream_structure()
        ) :: state()
  defp start_parsing_engine(state, framerate, input_alignment, input_stream_structure) do
    parsing_engine =
      ParsingEngine.new(%{
        codec: state.codec,
        input_stream_structure: input_stream_structure,
        input_alignment: input_alignment,
        output_stream_structure: state.output_stream_structure,
        repeat_parameter_sets: state.repeat_parameter_sets,
        initial_parameter_sets: state.initial_parameter_sets,
        generate_best_effort_timestamps: state.generate_best_effort_timestamps,
        infer_dts_from_pts: state.infer_dts_from_pts
      })

    %{
      state
      | parsing_engine: parsing_engine,
        framerate: framerate || state.framerate
    }
  end

  @spec process_events([ParsingEngine.event()], map(), state()) :: {[action()], state()}
  defp process_events(events, ctx, state) do
    {actions, {state, _last_stream_format}} =
      Enum.flat_map_reduce(events, {state, ctx.pads.output.stream_format}, fn
        {:parameter_sets, parameter_sets}, {state, last_stream_format} ->
          {actions, last_stream_format} =
            maybe_stream_format(parameter_sets, last_stream_format, state)

          {actions, {state, last_stream_format}}

        {:access_unit, au}, {state, last_stream_format} ->
          {actions, state} = prepare_buffer_actions(au, state)
          {actions, {state, last_stream_format}}
      end)

    {actions, state}
  end

  defp stream_format_module(:h264), do: Membrane.H264
  defp stream_format_module(:h265), do: Membrane.H265

  defp maybe_stream_format(parameter_sets, last_stream_format, state) do
    case generate_stream_format(parameter_sets, last_stream_format, state) do
      nil -> {[], last_stream_format}
      ^last_stream_format -> {[], last_stream_format}
      stream_format -> {[stream_format: {:output, stream_format}], stream_format}
    end
  end

  defp generate_stream_format(
         %{
           active: active_parameter_sets,
           output_raw_stream_structure: output_raw_stream_structure
         },
         last_stream_format,
         state
       ) do
    latest_sps = active_parameter_sets |> Enum.filter(&(&1.type == :sps)) |> List.last()

    case {latest_sps, last_stream_format} do
      {nil, nil} ->
        nil

      {nil, last_stream_format} ->
        %{last_stream_format | stream_structure: output_raw_stream_structure}

      {latest_sps, _last_stream_format} ->
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

  defp keyframe_from_metadata(metadata, codec) do
    case metadata do
      %{^codec => %{key_frame?: keyframe?}} when is_boolean(keyframe?) ->
        keyframe?

      _metadata ->
        raise ArgumentError, """
        The input stream format declares the NALu metadata to be present \
        (`nalu_in_metadata?: true`), but the buffer metadata lacks the \
        `#{inspect(codec)}.key_frame?` field: #{inspect(metadata)}
        """
    end
  end

  defp framerate(false), do: nil
  defp framerate(%{framerate: framerate}), do: framerate

  @spec prepare_buffer_actions(AccessUnit.t(), state()) :: {[action()], state()}
  defp prepare_buffer_actions(au, state) do
    skip_until_keyframe? = state.skip_until_keyframe and not au.keyframe?
    state = %{state | skip_until_keyframe: skip_until_keyframe?}

    if skip_until_keyframe? do
      {[], state}
    else
      buffers = wrap_into_buffer(au, state.output_alignment, _metadata_key = state.codec)
      {[buffer: {:output, buffers}], state}
    end
  end

  defp wrap_into_buffer(au, :au, metadata_key) do
    {pts, dts} = au.timestamps

    %Buffer{
      payload: join_payloads(au.nalus_payloads),
      metadata: prepare_metadata(:au, au.nalus, au.keyframe?, metadata_key),
      pts: pts,
      dts: dts
    }
  end

  defp wrap_into_buffer(au, :nalu, metadata_key) do
    {pts, dts} = au.timestamps

    au.nalus_payloads
    |> Enum.zip(prepare_metadata(:nalu, au.nalus, au.keyframe?, metadata_key))
    |> Enum.map(fn {nalu_payload, metadata} ->
      %Buffer{
        payload: nalu_payload,
        metadata: metadata,
        pts: pts,
        dts: dts
      }
    end)
  end

  defp stream_format_sent?(actions, %{pads: %{output: %{stream_format: nil}}}),
    do: Enum.any?(actions, &match?({:stream_format, _stream_format}, &1))

  defp stream_format_sent?(_actions, _ctx), do: true

  defp join_payloads([payload]), do: payload
  defp join_payloads(payloads), do: IO.iodata_to_binary(payloads)

  defp prepare_metadata(:au, nalus, keyframe?, metadata_key) do
    nalus = Enum.map(prepare_metadata(:nalu, nalus, keyframe?, metadata_key), &%{metadata: &1})
    %{metadata_key => %{key_frame?: keyframe?, nalus: nalus}}
  end

  defp prepare_metadata(:nalu, nalus, keyframe?, metadata_key) do
    nalus
    |> Enum.map(&%{metadata_key => %{type: &1.type}})
    |> List.update_at(0, &put_in(&1, [metadata_key, :new_access_unit], %{key_frame?: keyframe?}))
    |> List.update_at(-1, &put_in(&1, [metadata_key, :end_access_unit], true))
  end
end
