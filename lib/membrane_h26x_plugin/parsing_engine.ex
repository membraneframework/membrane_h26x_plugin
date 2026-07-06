defmodule Membrane.H26x.ParsingEngine do
  @moduledoc """
  Membrane-agnostic H26x parsing engine.

  Splits incoming payloads into NAL units, parses them and groups them into
  access units, optionally generating best-effort timestamps. Codec-specific
  behaviour is provided via the modules passed in the `t:config/0`.
  """

  alias Membrane.H26x.NALu

  alias Membrane.H26x.ParsingEngine.{
    AUSplitter,
    AUTimestampGenerator,
    NALuParser,
    NALuSplitter
  }

  @type stream_structure ::
          Membrane.H264.Parser.stream_structure() | Membrane.H265.Parser.stream_structure()

  @type mode :: :bytestream | :nalu_aligned | :au_aligned

  @typedoc """
  An access unit - a list of logically associated NAL units.
  """
  @type access_unit :: [NALu.t()]

  @type config :: %{
          input_stream_structure: stream_structure(),
          mode: mode(),
          nalu_parser_mod: module(),
          au_splitter_mod: module(),
          au_timestamp_generator_mod: module(),
          generate_best_effort_timestamps:
            false
            | %{
                :framerate => {frames :: pos_integer(), seconds :: pos_integer()},
                optional(:add_dts_offset) => boolean()
              }
        }

  @typedoc false
  @type t :: %__MODULE__{
          nalu_splitter: NALuSplitter.t(),
          nalu_parser: NALuParser.t(),
          au_splitter: AUSplitter.t(),
          au_timestamp_generator: AUTimestampGenerator.state() | nil,
          mode: mode(),
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
    :mode,
    :input_stream_structure,
    :nalu_parser_mod,
    :au_splitter_mod,
    :au_timestamp_generator_mod
  ]
  defstruct @enforce_keys ++ [previous_buffer_timestamps: nil, pending_payload: <<>>]

  @doc """
  Creates a parser for the given input stream structure and mode.
  """
  @spec new(config()) :: t()
  def new(config) do
    au_timestamp_generator =
      case config.generate_best_effort_timestamps do
        false -> nil
        cfg -> AUTimestampGenerator.new(config.au_timestamp_generator_mod, cfg)
      end

    %__MODULE__{
      nalu_splitter: NALuSplitter.new(config.input_stream_structure),
      nalu_parser: NALuParser.new(config.input_stream_structure),
      au_splitter: AUSplitter.new(),
      au_timestamp_generator: au_timestamp_generator,
      mode: config.mode,
      input_stream_structure: config.input_stream_structure,
      nalu_parser_mod: config.nalu_parser_mod,
      au_splitter_mod: config.au_splitter_mod,
      au_timestamp_generator_mod: config.au_timestamp_generator_mod
    }
  end

  @doc """
  Changes the parser mode, keeping the accumulated parsing state. To be used after
  `flush/1` when the input alignment changes mid-stream.
  """
  @spec set_mode(t(), mode()) :: t()
  def set_mode(engine, mode), do: %{engine | mode: mode}

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
  Feeds a payload through the parser, returning the access units completed by it.
  """
  @spec push(t(), binary(), NALu.timestamps()) :: {[access_unit()], t()}
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
  Drains all buffered data into access units. To be used on a mode change or end of stream.
  """
  @spec flush(t()) :: {[access_unit()], t()}
  def flush(engine) do
    parse(engine, <<>>, engine.previous_buffer_timestamps || {nil, nil}, _flush? = true)
  end

  @spec parse(t(), binary(), NALu.timestamps(), boolean()) :: {[access_unit()], t()}
  defp parse(engine, payload, timestamps, flush?) do
    {nalus_payloads, nalu_splitter} =
      NALuSplitter.split(payload, flush? or engine.mode != :bytestream, engine.nalu_splitter)

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
        flush? or engine.mode == :au_aligned,
        engine.au_splitter
      )

    engine = %{
      engine
      | nalu_splitter: nalu_splitter,
        nalu_parser: nalu_parser,
        au_splitter: au_splitter
    }

    maybe_generate_timestamps(access_units, flush?, engine)
  end

  defguardp is_timestamp_generator_active(engine)
            when engine.mode == :bytestream and not is_nil(engine.au_timestamp_generator)

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
