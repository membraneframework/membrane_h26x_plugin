defmodule Membrane.H26x.ParsingEngine do
  @moduledoc """
  Membrane-agnostic H26x parsing engine.

  Splits incoming payloads into NAL units, parses them and groups them into
  access units, optionally generating best-effort timestamps. The access units
  are returned interleaved with parameter set change notifications - see
  `t:event/0`. Depending on the configured output stream structure, the engine
  also repeats the active parameter sets on keyframes or strips them from the
  access units altogether (for the structures conveying them out-of-band).
  Codec-specific behaviour is selected via the `:codec` field of `t:config/0`.
  """

  alias Membrane.H26x.NALu

  alias Membrane.H26x.ParsingEngine.{
    AUSplitter,
    AUTimestampGenerator,
    NALuParser,
    NALuSplitter,
    ParameterSetCache
  }

  @type codec :: :h264 | :h265

  @typedoc """
  Structure of the H26x stream - either Annex B, where the NALus are separated by
  a start code (`0x(00)000001`), or length-prefixed (as described in *ISO/IEC 14496-15*),
  where each NALu is prefixed with its length.
  """
  @type stream_structure ::
          :annexb
          | {codec_tag :: :avc1 | :avc3 | :hvc1 | :hev1, nalu_length_size :: pos_integer()}

  @typedoc """
  The structure of the input stream.

  For the length-prefixed structures (`:avc1`, `:avc3`, `:hvc1`, `:hev1`), instead of the
  NALu length size, a Decoder Configuration Record binary (e.g. coming from an MP4 container)
  may be provided - the NALu length size is then read from it and the parameter sets it
  carries are scheduled to be parsed before the first pushed payload.
  """
  @type input_stream_structure ::
          stream_structure()
          | {codec_tag :: :avc1 | :avc3 | :hvc1 | :hev1, dcr :: binary()}

  @typedoc """
  Alignment of the payloads fed to the engine - an arbitrary stream of bytes (`:bytestream`),
  a single NAL unit per payload (`:nalu`) or a whole access unit per payload (`:au`).
  """
  @type input_alignment :: :bytestream | :nalu | :au

  @typedoc """
  An access unit - a list of logically associated NAL units.
  """
  @type access_unit :: [NALu.t()]

  @typedoc """
  An item of the engine's output.

  Access units are interleaved with parameter set change notifications: whenever the
  set of active parameter sets changes, a `:parameter_sets` event is emitted right
  before the access unit that introduced the change. The event carries all the
  parameter sets active at that point of the stream (the most recent set per
  parameter set type and id) and a Decoder Configuration Record generated out of
  them (`nil` for the `:annexb` output stream structure, or when no SPS has been
  seen yet).
  """
  @type event ::
          {:access_unit, access_unit()}
          | {:parameter_sets, %{dcr: binary() | nil, active: [NALu.t()]}}

  @typedoc """
  If set to a map, timestamps are generated based on the provided constant framerate
  (available only for the `:bytestream` input alignment). `:add_dts_offset` shifts DTS values so that
  they don't exceed PTS values, defaults to `true`.
  """
  @type generate_best_effort_timestamps ::
          false
          | %{
              :framerate => {frames :: pos_integer(), seconds :: pos_integer()},
              optional(:add_dts_offset) => boolean()
            }

  @typedoc """
  Configuration of the parsing engine:
  * `:codec` - the codec of the parsed stream, either `:h264` or `:h265`.
  * `:input_stream_structure` - see `t:input_stream_structure/0`.
  * `:input_alignment` - see `t:input_alignment/0`.
  * `:output_stream_structure` - the stream structure the output access units are
    intended for. Determines how the parameter sets are handled: for the structures
    conveying them out-of-band (`:avc1`, `:hvc1`) they are stripped from the access
    units and carried solely by the DCRs of the `:parameter_sets` events. Defaults
    to the input stream structure.
  * `:repeat_parameter_sets` - if `true`, all the active parameter sets are attached
    to each keyframe access unit. Takes no effect for the `:avc1` and `:hvc1` output
    stream structures, where the parameter sets travel out-of-band. Defaults to `false`.
  * `:generate_best_effort_timestamps` - see `t:generate_best_effort_timestamps/0`.
    Defaults to `false`.
  """
  @type config :: %{
          :codec => codec(),
          :input_stream_structure => input_stream_structure(),
          :input_alignment => input_alignment(),
          optional(:output_stream_structure) => stream_structure(),
          optional(:repeat_parameter_sets) => boolean(),
          optional(:generate_best_effort_timestamps) => generate_best_effort_timestamps()
        }

  @typedoc false
  @type t :: %__MODULE__{
          codec: codec(),
          nalu_splitter: NALuSplitter.t(),
          nalu_parser: NALuParser.t(),
          au_splitter: AUSplitter.t(),
          au_timestamp_generator: AUTimestampGenerator.state() | nil,
          parameter_set_cache: ParameterSetCache.t(),
          input_alignment: input_alignment(),
          input_stream_structure: stream_structure(),
          output_stream_structure: stream_structure(),
          repeat_parameter_sets: boolean(),
          previous_buffer_timestamps: NALu.timestamps() | nil,
          pending_payload: binary(),
          nalu_parser_mod: module(),
          au_splitter_mod: module(),
          au_timestamp_generator_mod: module()
        }

  @enforce_keys [
    :codec,
    :nalu_splitter,
    :nalu_parser,
    :au_splitter,
    :au_timestamp_generator,
    :parameter_set_cache,
    :input_alignment,
    :input_stream_structure,
    :output_stream_structure,
    :repeat_parameter_sets,
    :nalu_parser_mod,
    :au_splitter_mod,
    :au_timestamp_generator_mod
  ]
  defstruct @enforce_keys ++ [previous_buffer_timestamps: nil, pending_payload: <<>>]

  @doc """
  Creates a parser for the given input stream structure and alignment.

  Raises an `ArgumentError` if the configured codec is not supported.
  """
  @spec new(config()) :: t()
  def new(%{codec: codec} = config) when codec in [:h264, :h265] do
    {input_stream_structure, parameter_sets} =
      resolve_input_stream_structure(config.codec, config.input_stream_structure)

    au_timestamp_generator =
      case Map.get(config, :generate_best_effort_timestamps, false) do
        false -> nil
        cfg -> AUTimestampGenerator.new(au_timestamp_generator_mod(config.codec), cfg)
      end

    %__MODULE__{
      codec: codec,
      nalu_splitter: NALuSplitter.new(input_stream_structure),
      nalu_parser: NALuParser.new(input_stream_structure),
      au_splitter: AUSplitter.new(),
      au_timestamp_generator: au_timestamp_generator,
      parameter_set_cache: ParameterSetCache.new(),
      input_alignment: config.input_alignment,
      input_stream_structure: input_stream_structure,
      output_stream_structure:
        Map.get(config, :output_stream_structure) || input_stream_structure,
      repeat_parameter_sets: Map.get(config, :repeat_parameter_sets, false),
      nalu_parser_mod: nalu_parser_mod(config.codec),
      au_splitter_mod: au_splitter_mod(config.codec),
      au_timestamp_generator_mod: au_timestamp_generator_mod(config.codec)
    }
    |> prepend_parameter_sets(parameter_sets)
  end

  def new(config) do
    raise ArgumentError,
          "Unsupported codec: #{inspect(config[:codec])}. The supported codecs are :h264 and :h265."
  end

  @spec resolve_input_stream_structure(codec(), input_stream_structure()) ::
          {stream_structure(), [binary()]}
  defp resolve_input_stream_structure(codec, {codec_tag, dcr}) when is_binary(dcr) do
    dcr = dcr_module(codec).parse(dcr)
    {{codec_tag, dcr.nalu_length_size}, dcr_parameter_sets(codec, dcr)}
  end

  defp resolve_input_stream_structure(_codec, stream_structure), do: {stream_structure, []}

  defp dcr_parameter_sets(:h264, dcr), do: dcr.spss ++ dcr.ppss
  defp dcr_parameter_sets(:h265, dcr), do: dcr.vpss ++ dcr.spss ++ dcr.ppss

  @doc """
  Tells whether the access unit contains a keyframe.
  """
  @spec keyframe?(codec(), access_unit()) :: boolean()
  def keyframe?(codec, access_unit),
    do: Enum.any?(access_unit, &(&1.type in keyframe_nalu_types(codec)))

  defp keyframe_nalu_types(:h264), do: [:idr]

  defp keyframe_nalu_types(:h265),
    do: [:bla_w_lp, :bla_w_radl, :bla_n_lp, :idr_w_radl, :idr_n_lp, :cra]

  defp dcr_module(:h264), do: Membrane.H264.DecoderConfigurationRecord
  defp dcr_module(:h265), do: Membrane.H265.DecoderConfigurationRecord

  defp nalu_parser_mod(:h264), do: Membrane.H264.NALuParser
  defp nalu_parser_mod(:h265), do: Membrane.H265.NALuParser

  defp au_splitter_mod(:h264), do: Membrane.H264.AUSplitter
  defp au_splitter_mod(:h265), do: Membrane.H265.AUSplitter

  defp au_timestamp_generator_mod(:h264), do: Membrane.H264.AUTimestampGenerator
  defp au_timestamp_generator_mod(:h265), do: Membrane.H265.AUTimestampGenerator

  @doc """
  Changes the input alignment, keeping the accumulated parsing state. To be used after
  `flush/1` when the input alignment changes mid-stream.
  """
  @spec set_input_alignment(t(), input_alignment()) :: t()
  def set_input_alignment(engine, input_alignment),
    do: %{engine | input_alignment: input_alignment}

  @doc """
  Schedules raw (unprefixed) parameter set payloads to be parsed just before the next
  pushed payload, as if they preceded it in the stream.
  """
  @spec prepend_parameter_sets(t(), [binary()]) :: t()
  def prepend_parameter_sets(engine, parameter_sets) do
    prefixed = NALuParser.prefix_nalus_payloads(parameter_sets, engine.input_stream_structure)
    %{engine | pending_payload: engine.pending_payload <> prefixed}
  end

  @doc """
  Returns the NALu's payload with the prefix fitting the given stream structure.
  """
  @spec get_prefixed_nalu_payload(NALu.t(), stream_structure()) :: binary()
  defdelegate get_prefixed_nalu_payload(nalu, stream_structure), to: NALuParser

  @doc """
  Returns the parameter sets currently active in the stream - the most recent set
  per parameter set type and id.
  """
  @spec active_parameter_sets(t()) :: [NALu.t()]
  def active_parameter_sets(engine), do: engine.parameter_set_cache

  @doc """
  Feeds a payload through the parser, returning the access units completed by it,
  interleaved with parameter set change notifications - see `t:event/0`.
  """
  @spec push(t(), binary(), NALu.timestamps()) :: {[event()], t()}
  def push(engine, payload, timestamps \\ {nil, nil}) do
    {pts, dts} = timestamps
    payload = engine.pending_payload <> payload

    engine = %{
      engine
      | pending_payload: <<>>,
        previous_buffer_timestamps: {pts || dts, dts || pts}
    }

    parse(engine, payload, timestamps, _flush? = false)
  end

  @doc """
  Drains all buffered data into access units. To be used on an input alignment change
  or end of stream.
  """
  @spec flush(t()) :: {[event()], t()}
  def flush(engine) do
    parse(engine, <<>>, engine.previous_buffer_timestamps || {nil, nil}, _flush? = true)
  end

  @spec parse(t(), binary(), NALu.timestamps(), boolean()) :: {[event()], t()}
  defp parse(engine, payload, timestamps, flush?) do
    {nalus_payloads, nalu_splitter} =
      NALuSplitter.split(
        payload,
        flush? or engine.input_alignment != :bytestream,
        engine.nalu_splitter
      )

    {nalus, nalu_parser} =
      NALuParser.parse_nalus(
        engine.nalu_parser_mod,
        nalus_payloads,
        timestamps,
        engine.nalu_parser
      )

    {access_units, au_splitter} =
      AUSplitter.split(
        engine.au_splitter_mod,
        nalus,
        flush? or engine.input_alignment == :au,
        engine.au_splitter
      )

    engine = %{
      engine
      | nalu_splitter: nalu_splitter,
        nalu_parser: nalu_parser,
        au_splitter: au_splitter
    }

    {access_units, engine} = maybe_generate_timestamps(access_units, flush?, engine)

    {events, parameter_set_cache} =
      Enum.flat_map_reduce(access_units, engine.parameter_set_cache, fn au, cache ->
        updated_cache = ParameterSetCache.put(cache, au)
        au_event = {:access_unit, finalize_access_unit(engine, au, updated_cache)}

        if updated_cache == cache do
          {[au_event], cache}
        else
          parameter_sets = %{dcr: generate_dcr(engine, updated_cache), active: updated_cache}
          {[{:parameter_sets, parameter_sets}, au_event], updated_cache}
        end
      end)

    {events, %{engine | parameter_set_cache: parameter_set_cache}}
  end

  @spec generate_dcr(t(), [NALu.t()]) :: binary() | nil
  defp generate_dcr(%{output_stream_structure: :annexb}, _parameter_sets), do: nil

  defp generate_dcr(engine, parameter_sets),
    do: dcr_module(engine.codec).generate(parameter_sets, engine.output_stream_structure)

  @spec finalize_access_unit(t(), access_unit(), [NALu.t()]) :: access_unit()
  defp finalize_access_unit(engine, au, active_parameter_sets) do
    cond do
      strip_parameter_sets?(engine) ->
        Enum.reject(au, &ParameterSetCache.parameter_set?/1)

      keyframe?(engine.codec, au) ->
        au = if engine.repeat_parameter_sets, do: active_parameter_sets ++ au, else: au
        Enum.uniq_by(au, & &1.payload)

      true ->
        au
    end
  end

  defp strip_parameter_sets?(%{output_stream_structure: :annexb}), do: false

  defp strip_parameter_sets?(engine) do
    {codec_tag, _nalu_length_size} = engine.output_stream_structure
    codec_tag in out_of_band_parameter_sets_codec_tags(engine.codec)
  end

  defp out_of_band_parameter_sets_codec_tags(:h264), do: [:avc1]
  defp out_of_band_parameter_sets_codec_tags(:h265), do: [:hvc1]

  defguardp is_timestamp_generator_active(engine)
            when engine.input_alignment == :bytestream and
                   not is_nil(engine.au_timestamp_generator)

  @spec maybe_generate_timestamps([access_unit()], boolean(), t()) :: {[access_unit()], t()}
  defp maybe_generate_timestamps(aus, flush?, engine)
       when is_timestamp_generator_active(engine) do
    {aus, generator} =
      AUTimestampGenerator.generate_timestamps(
        engine.au_timestamp_generator_mod,
        aus,
        flush?,
        engine.au_timestamp_generator
      )

    {aus, %{engine | au_timestamp_generator: generator}}
  end

  defp maybe_generate_timestamps(aus, _flush?, engine), do: {aus, engine}
end
