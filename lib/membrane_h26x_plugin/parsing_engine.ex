defmodule Membrane.H26x.ParsingEngine do
  @moduledoc """
  Membrane-agnostic H26x parsing engine.

  Splits incoming payloads into NAL units, parses them and groups them into
  access units, optionally generating best-effort timestamps. Each produced
  access unit is annotated with the parameter sets active at its position in
  the stream. Codec-specific behaviour is selected via the `:codec` field of
  `t:config/0`.
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
  An access unit annotated with the parameter sets active at its position in the
  stream - the most recent set per parameter set type and id, including the sets
  carried by the access unit itself.
  """
  @type access_unit_with_parameter_sets :: {access_unit(), [NALu.t()]}

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
  * `:generate_best_effort_timestamps` - see `t:generate_best_effort_timestamps/0`.
    Defaults to `false`.
  """
  @type config :: %{
          :codec => codec(),
          :input_stream_structure => input_stream_structure(),
          :input_alignment => input_alignment(),
          optional(:generate_best_effort_timestamps) => generate_best_effort_timestamps()
        }

  @typedoc false
  @type t :: %__MODULE__{
          nalu_splitter: NALuSplitter.t(),
          nalu_parser: NALuParser.t(),
          au_splitter: AUSplitter.t(),
          au_timestamp_generator: AUTimestampGenerator.state() | nil,
          parameter_set_cache: ParameterSetCache.t(),
          input_alignment: input_alignment(),
          input_stream_structure: stream_structure(),
          previous_buffer_timestamps: NALu.timestamps() | nil,
          pending_payload: binary(),
          nalu_parser_mod: module(),
          au_splitter_mod: module(),
          au_timestamp_generator_mod: module()
        }

  @enforce_keys [
    :nalu_splitter,
    :nalu_parser,
    :au_splitter,
    :au_timestamp_generator,
    :parameter_set_cache,
    :input_alignment,
    :input_stream_structure,
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
      nalu_splitter: NALuSplitter.new(input_stream_structure),
      nalu_parser: NALuParser.new(input_stream_structure),
      au_splitter: AUSplitter.new(),
      au_timestamp_generator: au_timestamp_generator,
      parameter_set_cache: ParameterSetCache.new(),
      input_alignment: config.input_alignment,
      input_stream_structure: input_stream_structure,
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

  @doc false
  @spec generate_dcr(codec(), [NALu.t()], stream_structure()) :: binary() | nil
  def generate_dcr(codec, parameter_sets, stream_structure) do
    dcr_module(codec).generate(parameter_sets, stream_structure)
  end

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
  Feeds a payload through the parser, returning the access units completed by it.
  """
  @spec push(t(), binary(), NALu.timestamps()) :: {[access_unit_with_parameter_sets()], t()}
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
  @spec flush(t()) :: {[access_unit_with_parameter_sets()], t()}
  def flush(engine) do
    parse(engine, <<>>, engine.previous_buffer_timestamps || {nil, nil}, _flush? = true)
  end

  @spec parse(t(), binary(), NALu.timestamps(), boolean()) ::
          {[access_unit_with_parameter_sets()], t()}
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

    {access_units, parameter_set_cache} =
      Enum.map_reduce(access_units, engine.parameter_set_cache, fn au, cache ->
        cache = ParameterSetCache.put(cache, au)
        {{au, cache}, cache}
      end)

    {access_units, %{engine | parameter_set_cache: parameter_set_cache}}
  end

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
