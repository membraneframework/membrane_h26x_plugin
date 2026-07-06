defmodule Membrane.H26x.Parser.Core do
  @moduledoc false

  # Membrane-agnostic H26x parser.

  alias Membrane.H26x.{AUSplitter, AUTimestampGenerator, NALu, NALuParser, NALuSplitter}

  @type stream_structure ::
          Membrane.H264.Parser.stream_structure() | Membrane.H265.Parser.stream_structure()

  @type mode :: :bytestream | :nalu_aligned | :au_aligned
  @type access_unit :: AUSplitter.access_unit()

  @type config :: %{
          input_stream_structure: stream_structure(),
          mode: mode(),
          nalu_parser_mod: module(),
          au_splitter_mod: module(),
          au_timestamp_generator_mod: module(),
          generate_best_effort_timestamps: false | AUTimestampGenerator.config()
        }

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
  def set_mode(core, mode), do: %{core | mode: mode}

  @doc """
  Schedules raw (unprefixed) parameter set payloads to be parsed just before the next
  pushed payload, as if they preceded it in the stream.
  """
  @spec prepend_parameter_sets(t(), [binary()]) :: t()
  def prepend_parameter_sets(core, parameter_sets) do
    prefixed = NALuParser.prefix_nalus_payloads(parameter_sets, core.input_stream_structure)
    %{core | pending_payload: core.pending_payload <> prefixed}
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
  def push(core, payload, timestamps \\ {nil, nil}) do
    {pts, dts} = timestamps
    payload = core.pending_payload <> payload

    core = %{
      core
      | pending_payload: <<>>,
        previous_buffer_timestamps: {pts || dts, dts || pts}
    }

    parse(core, payload, timestamps, _flush? = false)
  end

  @doc """
  Drains all buffered data into access units. To be used on a mode change or end of stream.
  """
  @spec flush(t()) :: {[access_unit()], t()}
  def flush(core) do
    parse(core, <<>>, core.previous_buffer_timestamps || {nil, nil}, _flush? = true)
  end

  @spec parse(t(), binary(), NALu.timestamps(), boolean()) :: {[access_unit()], t()}
  defp parse(core, payload, timestamps, flush?) do
    {nalus_payloads, nalu_splitter} =
      NALuSplitter.split(payload, flush? or core.mode != :bytestream, core.nalu_splitter)

    {nalus, nalu_parser} =
      NALuParser.parse_nalus(core.nalu_parser_mod, nalus_payloads, timestamps, core.nalu_parser)

    {access_units, au_splitter} =
      AUSplitter.split(
        core.au_splitter_mod,
        nalus,
        flush? or core.mode == :au_aligned,
        core.au_splitter
      )

    core = %{
      core
      | nalu_splitter: nalu_splitter,
        nalu_parser: nalu_parser,
        au_splitter: au_splitter
    }

    maybe_generate_timestamps(access_units, flush?, core)
  end

  defguardp is_timestamp_generator_active(core)
            when core.mode == :bytestream and not is_nil(core.au_timestamp_generator)

  @spec maybe_generate_timestamps([access_unit()], boolean(), t()) :: {[access_unit()], t()}
  defp maybe_generate_timestamps(aus, flush?, core) when is_timestamp_generator_active(core) do
    {aus, generator} =
      AUTimestampGenerator.generate_timestamps(
        core.au_timestamp_generator_mod,
        aus,
        flush?,
        core.au_timestamp_generator
      )

    {aus, %{core | au_timestamp_generator: generator}}
  end

  defp maybe_generate_timestamps(aus, _flush?, core), do: {aus, core}
end
