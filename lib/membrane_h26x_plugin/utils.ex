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
          output_alignment: :au | :nalu,
          skip_until_keyframe: boolean(),
          repeat_parameter_sets: boolean(),
          initial_parameter_sets: [binary()],
          output_stream_structure: ParsingEngine.stream_structure() | nil,
          framerate: term() | nil
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
      output_stream_structure: opts[:output_stream_structure],
      framerate: framerate(opts[:generate_best_effort_timestamps])
    }
  end

  @doc """
  Handles a new input stream format.

  The element passes the input alignment and the raw input stream structure resolved
  from the stream format, along with the stream's framerate (or `nil`).
  """
  @spec handle_stream_format(
          {ParsingEngine.input_alignment(), ParsingEngine.input_stream_structure()},
          term() | nil,
          map(),
          state()
        ) :: {[action()], state()}
  def handle_stream_format({alignment, input_stream_structure}, framerate, ctx, state) do
    if is_nil(ctx.pads.output.stream_format) do
      {[], start_parsing_engine(state, framerate, alignment, input_stream_structure)}
    else
      {events, parsing_engine} =
        ParsingEngine.reconfigure_input(state.parsing_engine, alignment, input_stream_structure)

      process_events(events, ctx, %{state | parsing_engine: parsing_engine})
    end
  end

  @doc """
  Handles an input buffer.
  """
  @spec handle_buffer(Buffer.t(), map(), state()) :: {[action()], state()}
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
        generate_best_effort_timestamps: state.generate_best_effort_timestamps
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
      payload: Enum.join(au.nalus_payloads),
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
