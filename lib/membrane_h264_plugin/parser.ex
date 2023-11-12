defmodule Membrane.H26x.Parser do
  @moduledoc false

  alias Membrane.H26x.AUSplitter

  @typedoc """
  Stream structure of the NALUs. In case it's not `:annexb` format, it contains an information
  about the size of each NALU's prefix describing their length.
  """
  @type stream_structure :: :annexb | {codec_tag :: atom(), nalu_length_size :: pos_integer()}

  @type parameter_sets :: tuple()
  @type stream_format :: Membrane.StreamFormat.t()
  @type state :: Membrane.Element.state()
  @type alignment :: :bytestream | :nalu | :au
  @type raw_stream_structure ::
          :annexb | {codec_tag :: atom(), decoder_configuration_record :: binary()}

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

  @optional_callbacks parse_raw_input_stream_structure: 1,
                      remove_parameter_sets_from_stream?: 1,
                      generate_stream_format: 3,
                      get_parameter_sets: 1,
                      keyframe?: 1

  defmacro __using__(options) do
    au_splitter = Keyword.fetch!(options, :au_splitter)
    nalu_parser = Keyword.fetch!(options, :nalu_parser)
    au_timestamp_generator = Keyword.fetch!(options, :au_timestamp_generator)
    metadata_key = Keyword.fetch!(options, :metadata_key)

    quote location: :keep do
      use Membrane.Filter

      @behaviour unquote(__MODULE__)

      alias Membrane.Buffer
      alias Membrane.Element.{Action, CallbackContext}
      alias Membrane.H26x.{AUSplitter, AUTimestampGenerator, NALu, NALuSplitter}

      @typep stream_format :: Membrane.StreamFormat.t()
      @typep state :: Membrane.Element.state()
      @typep callback_return :: Membrane.Element.Base.callback_return()

      @impl true
      def handle_init(_ctx, opts) do
        {au_timestamp_generator, framerate} =
          get_timestamp_generator(opts.generate_best_effort_timestamps)

        state =
          %{
            nalu_splitter: nil,
            nalu_parser: nil,
            au_splitter: unquote(au_splitter).new(),
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
            output_stream_structure: opts.output_stream_structure
          }

        {[], state}
      end

      @impl true
      def handle_stream_format(:input, stream_format, ctx, state) do
        {alignment, input_stream_structure, parameter_sets} =
          parse_raw_input_stream_structure(stream_format)

        is_first_received_stream_format = is_nil(ctx.pads.output.stream_format)

        mode = get_mode_from_alignment(alignment)

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
                  nalu_parser: unquote(nalu_parser).new(input_stream_structure),
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
              {actions, state} = clean_state(state, ctx)
              state = %{state | mode: mode}
              {actions, state}

            true ->
              state
          end

        incoming_parameter_sets =
          get_stream_format_parameter_sets(
            input_stream_structure,
            parameter_sets,
            is_first_received_stream_format,
            state
          )

        process_stream_format_parameter_sets(
          incoming_parameter_sets,
          ctx.pads.output.stream_format,
          state
        )
      end

      @impl true
      def handle_buffer(:input, %Membrane.Buffer{} = buffer, ctx, state) do
        old_stream_format = ctx.pads.output.stream_format

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
          unquote(nalu_parser).parse_nalus(nalus_payloads, timestamps, state.nalu_parser)

        is_au_aligned = state.mode == :au_aligned

        {access_units, au_splitter} =
          unquote(au_splitter).split(nalus, is_au_aligned, state.au_splitter)

        {actions, state} = prepare_actions_for_aus(access_units, ctx, state)

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
        {last_nalu_payload, nalu_splitter} = NALuSplitter.split(<<>>, true, state.nalu_splitter)

        {last_nalu, nalu_parser} =
          unquote(nalu_parser).parse_nalus(last_nalu_payload, state.nalu_parser)

        {aus, au_splitter} = unquote(au_splitter).split(last_nalu, true, state.au_splitter)
        {actions, state} = prepare_actions_for_aus(aus, ctx, state)

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

      @impl true
      def parse_raw_input_stream_structure(stream_structure) do
        raise "parse_raw_input_stream_structure/1 not implemented"
      end

      @impl true
      def remove_parameter_sets_from_stream?(stream_structure) do
        raise "remove_parameter_sets_from_stream?/1 not implemented"
      end

      @impl true
      def generate_stream_format(parameter_sets, last_sent_stream_format, state) do
        raise "generate_stream_format/3 not implemented"
      end

      @impl true
      def get_parameter_sets(au) do
        raise "get_parameter_sets/1 not implemented"
      end

      @impl true
      def keyframe?(au) do
        raise "keyframe?/1 not implemented"
      end

      @spec get_timestamp_generator(false | map()) :: term()
      defp get_timestamp_generator(false), do: {nil, nil}

      defp get_timestamp_generator(generate_best_effort_timestamps) do
        {unquote(au_timestamp_generator).new(generate_best_effort_timestamps),
         generate_best_effort_timestamps.framerate}
      end

      @spec get_mode_from_alignment(:au | :nalu | :bytestream) ::
              :au_aligned | :nalu_aligned | :bytestream
      defp get_mode_from_alignment(alignment) do
        case alignment do
          :au -> :au_aligned
          :nalu -> :nalu_aligned
          :bytestream -> :bytestream
        end
      end

      @spec is_input_stream_structure_change_allowed?(
              unquote(__MODULE__).stream_structure(),
              unquote(__MODULE__).stream_structure()
            ) :: boolean()
      defp is_input_stream_structure_change_allowed?(:annexb, :annexb), do: true
      defp is_input_stream_structure_change_allowed?({codec_tag, _}, {codec_tag, _}), do: true

      defp is_input_stream_structure_change_allowed?(_stream_structure1, _stream_structure2),
        do: false

      @spec get_stream_format_parameter_sets(
              unquote(__MODULE__).stream_structure(),
              unquote(__MODULE__).parameter_sets(),
              boolean(),
              state()
            ) :: unquote(__MODULE__).parameter_sets()
      defp get_stream_format_parameter_sets(:annexb, _pss, is_first_received_stream_format, state) do
        if is_first_received_stream_format,
          do: state.initial_parameter_sets,
          else: empty_parameter_sets(state.initial_parameter_sets)
      end

      defp get_stream_format_parameter_sets(
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

      defp empty_parameter_sets(parameter_sets) do
        Enum.map(1..tuple_size(parameter_sets), fn _id -> [] end)
        |> List.to_tuple()
      end

      @spec process_stream_format_parameter_sets(
              unquote(__MODULE__).parameter_sets(),
              stream_format() | nil,
              state()
            ) :: callback_return()
      defp process_stream_format_parameter_sets(parameter_sets, stream_format, state) do
        if remove_parameter_sets_from_stream?(state.output_stream_structure) do
          {parsed_parameter_sets, nalu_parser} =
            Enum.map_reduce(Tuple.to_list(parameter_sets), state.nalu_parser, fn ps,
                                                                                 nalu_parser ->
              unquote(nalu_parser).parse_nalus(ps, {nil, nil}, false, nalu_parser)
            end)

          state = %{state | nalu_parser: nalu_parser}
          process_new_parameter_sets(List.to_tuple(parsed_parameter_sets), stream_format, state)
        else
          frame_prefix =
            unquote(nalu_parser).prefix_nalus_payloads(
              flatten_parameter_sets(parameter_sets),
              state.input_stream_structure
            )

          {[], %{state | frame_prefix: frame_prefix}}
        end
      end

      @spec process_new_parameter_sets(
              unquote(__MODULE__).parameter_sets(),
              stream_format() | nil,
              state()
            ) :: callback_return()
      defp process_new_parameter_sets(parameter_sets, last_sent_stream_format, state) do
        updated_parameter_sets = merge_parameter_sets(parameter_sets, state.cached_parameter_sets)
        state = %{state | cached_parameter_sets: updated_parameter_sets}

        stream_format_candidate =
          generate_stream_format(parameter_sets, last_sent_stream_format, state)

        if stream_format_candidate in [last_sent_stream_format, nil] do
          {[], state}
        else
          {[stream_format: {:output, stream_format_candidate}],
           %{state | profile: stream_format_candidate.profile}}
        end
      end

      @spec prepare_actions_for_aus([AUSplitter.access_unit()], CallbackContext.t(), state()) ::
              callback_return()
      defp prepare_actions_for_aus(aus, ctx, state) do
        Enum.flat_map_reduce(aus, state, fn au, state ->
          {au, stream_format, state} = process_au_parameter_sets(au, ctx, state)
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

          {stream_format ++ buffers_actions, state}
        end)
      end

      @spec process_au_parameter_sets(AUSplitter.access_unit(), CallbackContext.t(), state()) ::
              {AUSplitter.access_unit(), [Action.t()], state()}
      defp process_au_parameter_sets(au, ctx, state) do
        old_stream_format = ctx.pads.output.stream_format
        parameter_sets = get_parameter_sets(au)

        {stream_format, state} =
          process_new_parameter_sets(parameter_sets, old_stream_format, state)

        au =
          if remove_parameter_sets_from_stream?(state.output_stream_structure) do
            Enum.filter(au, &(&1 not in flatten_parameter_sets(parameter_sets)))
          else
            maybe_add_parameter_sets(au, state)
            |> delete_duplicate_parameter_sets(state)
          end

        {au, stream_format, state}
      end

      @spec merge_parameter_sets(
              unquote(__MODULE__).parameter_sets(),
              unquote(__MODULE__).parameter_sets()
            ) :: unquote(__MODULE__).parameter_sets()
      defp merge_parameter_sets(new_parameter_sets, cached_parameter_sets) do
        Tuple.to_list(cached_parameter_sets)
        |> Enum.zip(Tuple.to_list(new_parameter_sets))
        |> Enum.map(fn {cached_pss, new_pss} ->
          payloads = Enum.map(cached_pss, & &1.payload)
          cached_pss ++ Enum.filter(new_pss, &(&1.payload not in payloads))
        end)
        |> List.to_tuple()
      end

      @spec maybe_add_parameter_sets(AUSplitter.access_unit(), state()) ::
              AUSplitter.access_unit()
      defp maybe_add_parameter_sets(au, %{repeat_parameter_sets: false}), do: au

      defp maybe_add_parameter_sets(au, state) do
        if keyframe?(au), do: flatten_parameter_sets(state.cached_parameter_sets) ++ au, else: au
      end

      @spec delete_duplicate_parameter_sets(AUSplitter.access_unit(), state()) ::
              AUSplitter.access_unit()
      defp delete_duplicate_parameter_sets(au, state) do
        if keyframe?(au), do: Enum.uniq(au), else: au
      end

      @spec skip_au?(AUSplitter.access_unit(), state()) :: {boolean(), state()}
      defp skip_au?(au, state) do
        has_seen_keyframe? =
          Enum.all?(au, &(&1.status == :valid)) and keyframe?(au)

        state = %{
          state
          | skip_until_keyframe: state.skip_until_keyframe and not has_seen_keyframe?
        }

        {Enum.any?(au, &(&1.status == :error)) or state.skip_until_keyframe, state}
      end

      @spec prepare_timestamps(AUSplitter.access_unit(), state()) ::
              {{Membrane.Time.t(), Membrane.Time.t()}, state()}
      defp prepare_timestamps(au, state) do
        if state.mode == :bytestream and state.au_timestamp_generator do
          {timestamps, timestamp_generator} =
            unquote(au_timestamp_generator).generate_ts_with_constant_framerate(
              au,
              state.au_timestamp_generator
            )

          {timestamps, %{state | au_timestamp_generator: timestamp_generator}}
        else
          {List.last(au).timestamps, state}
        end
      end

      @spec wrap_into_buffer(
              AUSplitter.access_unit(),
              Membrane.Time.t(),
              Membrane.Time.t(),
              :au | :nalu,
              state()
            ) :: Buffer.t() | [Buffer.t()]
      defp wrap_into_buffer(access_unit, pts, dts, :au, state) do
        Enum.reduce(access_unit, <<>>, fn nalu, acc ->
          acc <>
            unquote(nalu_parser).get_prefixed_nalu_payload(nalu, state.output_stream_structure)
        end)
        |> then(fn payload ->
          %Buffer{
            payload: payload,
            metadata: prepare_au_metadata(access_unit),
            pts: pts,
            dts: dts
          }
        end)
      end

      defp wrap_into_buffer(access_unit, pts, dts, :nalu, state) do
        access_unit
        |> Enum.zip(prepare_nalus_metadata(access_unit))
        |> Enum.map(fn {nalu, metadata} ->
          %Buffer{
            payload:
              unquote(nalu_parser).get_prefixed_nalu_payload(nalu, state.output_stream_structure),
            metadata: metadata,
            pts: pts,
            dts: dts
          }
        end)
      end

      @spec prepare_au_metadata(AUSplitter.access_unit()) :: Buffer.metadata()
      defp prepare_au_metadata(nalus) do
        is_keyframe? = keyframe?(nalus)

        nalus =
          nalus
          |> Enum.with_index()
          |> Enum.map(fn {nalu, i} ->
            %{metadata: Map.put(%{}, unquote(metadata_key), %{type: nalu.type})}
            |> Bunch.then_if(
              i == 0,
              &put_in(&1, [:metadata, unquote(metadata_key), :new_access_unit], %{
                key_frame?: is_keyframe?
              })
            )
            |> Bunch.then_if(
              i == length(nalus) - 1,
              &put_in(&1, [:metadata, unquote(metadata_key), :end_access_unit], true)
            )
          end)

        %{unquote(metadata_key) => %{key_frame?: is_keyframe?, nalus: nalus}}
      end

      @spec prepare_nalus_metadata(AUSplitter.access_unit()) :: [Buffer.metadata()]
      defp prepare_nalus_metadata(nalus) do
        is_keyframe? = keyframe?(nalus)

        Enum.with_index(nalus)
        |> Enum.map(fn {nalu, i} ->
          Map.put(%{}, unquote(metadata_key), %{type: nalu.type})
          |> Bunch.then_if(
            i == 0,
            &put_in(&1, [unquote(metadata_key), :new_access_unit], %{key_frame?: is_keyframe?})
          )
          |> Bunch.then_if(
            i == length(nalus) - 1,
            &put_in(&1, [unquote(metadata_key), :end_access_unit], true)
          )
        end)
      end

      @spec flatten_parameter_sets(unquote(__MODULE__).parameter_sets()) :: list()
      defp flatten_parameter_sets(parameter_sets) do
        Tuple.to_list(parameter_sets) |> List.flatten()
      end

      @spec stream_format_sent?([Action.t()], CallbackContext.t()) :: boolean()
      defp stream_format_sent?(actions, %{pads: %{output: %{stream_format: nil}}}),
        do: Enum.any?(actions, &match?({:stream_format, _stream_format}, &1))

      defp stream_format_sent?(_actions, _ctx), do: true

      defp clean_state(state, ctx) do
        {nalus_payloads, nalu_splitter} = NALuSplitter.split(<<>>, true, state.nalu_splitter)
        {nalus, nalu_parser} = unquote(nalu_parser).parse_nalus(nalus_payloads, state.nalu_parser)
        {access_units, au_splitter} = unquote(au_splitter).split(nalus, true, state.au_splitter)

        state = %{
          state
          | nalu_splitter: nalu_splitter,
            nalu_parser: nalu_parser,
            au_splitter: au_splitter
        }

        prepare_actions_for_aus(access_units, ctx, state)
      end

      defoverridable handle_init: 2,
                     parse_raw_input_stream_structure: 1,
                     remove_parameter_sets_from_stream?: 1,
                     generate_stream_format: 3,
                     get_parameter_sets: 1,
                     keyframe?: 1
    end
  end
end
