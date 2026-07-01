defmodule Membrane.H26x.Parser.Core do
  @moduledoc false

  # A pure, Membrane-agnostic core of the H26x parser.

  alias Membrane.H26x.{AUSplitter, AUTimestampGenerator, NALu, NALuParser, NALuSplitter}

  @type stream_structure ::
          Membrane.H264.Parser.stream_structure() | Membrane.H265.Parser.stream_structure()

  @type mode :: :bytestream | :nalu_aligned | :au_aligned
  @type timestamps :: {pts :: integer() | nil, dts :: integer() | nil}
  @type access_unit :: AUSplitter.access_unit()

  @type config :: %{
          nalu_parser_mod: module(),
          au_splitter_mod: module(),
          au_timestamp_generator_mod: module(),
          generate_best_effort_timestamps: false | AUTimestampGenerator.config(),
          output_stream_structure: stream_structure() | nil
        }

  @type t :: %__MODULE__{
          nalu_splitter: NALuSplitter.t() | nil,
          nalu_parser: NALuParser.t() | nil,
          au_splitter: AUSplitter.t(),
          au_timestamp_generator: AUTimestampGenerator.state() | nil,
          framerate: AUTimestampGenerator.framerate() | nil,
          mode: mode() | nil,
          previous_buffer_timestamps: timestamps() | nil,
          frame_prefix: binary(),
          cached_parameter_sets: [NALu.t()],
          input_stream_structure: stream_structure() | nil,
          output_stream_structure: stream_structure() | nil,
          nalu_parser_mod: module(),
          au_splitter_mod: module(),
          au_timestamp_generator_mod: module()
        }

  @enforce_keys [
    :au_splitter,
    :au_timestamp_generator,
    :framerate,
    :output_stream_structure,
    :nalu_parser_mod,
    :au_splitter_mod,
    :au_timestamp_generator_mod
  ]
  defstruct @enforce_keys ++
              [
                nalu_splitter: nil,
                nalu_parser: nil,
                mode: nil,
                previous_buffer_timestamps: nil,
                frame_prefix: <<>>,
                cached_parameter_sets: [],
                input_stream_structure: nil
              ]

  @doc """
  Creates a fresh parser core. The input stream structure is not known yet; it is
  set later via `init_input_structure/4`.
  """
  @spec new(config()) :: t()
  def new(config) do
    {au_timestamp_generator, framerate} =
      get_timestamp_generator(
        config.generate_best_effort_timestamps,
        config.au_timestamp_generator_mod
      )

    %__MODULE__{
      au_splitter: AUSplitter.new(),
      au_timestamp_generator: au_timestamp_generator,
      framerate: framerate,
      output_stream_structure: config.output_stream_structure,
      nalu_parser_mod: config.nalu_parser_mod,
      au_splitter_mod: config.au_splitter_mod,
      au_timestamp_generator_mod: config.au_timestamp_generator_mod
    }
  end

  @doc """
  Maps a NALu alignment to the parser mode it implies.
  """
  @spec mode_from_alignment(:au | :nalu | :bytestream) :: mode()
  def mode_from_alignment(:au), do: :au_aligned
  def mode_from_alignment(:nalu), do: :nalu_aligned
  def mode_from_alignment(:bytestream), do: :bytestream

  @doc """
  Tells whether the input stream structure is allowed to change from `old` to `new`
  in the middle of a stream (only the NALu prefix length may change, not the codec tag).
  """
  @spec input_stream_structure_change_allowed?(
          stream_structure(),
          stream_structure()
        ) :: boolean()
  def input_stream_structure_change_allowed?(:annexb, :annexb), do: true

  def input_stream_structure_change_allowed?(
        {codec_tag, _from_prefix_len},
        {codec_tag, _to_prefix_len}
      ),
      do: true

  def input_stream_structure_change_allowed?(_stream_structure1, _stream_structure2), do: false

  @spec mode(t()) :: mode() | nil
  def mode(%__MODULE__{mode: mode}), do: mode

  @spec input_stream_structure(t()) :: stream_structure() | nil
  def input_stream_structure(%__MODULE__{input_stream_structure: structure}), do: structure

  @spec output_stream_structure(t()) :: stream_structure() | nil
  def output_stream_structure(%__MODULE__{output_stream_structure: structure}), do: structure

  @spec framerate(t()) :: AUTimestampGenerator.framerate() | nil
  def framerate(%__MODULE__{framerate: framerate}), do: framerate

  @spec cached_parameter_sets(t()) :: [NALu.t()]
  def cached_parameter_sets(%__MODULE__{cached_parameter_sets: sets}), do: sets

  @doc """
  Configures the core with the input stream structure derived from the first stream
  format. Initializes the NALu splitter and parser, defaults the output stream
  structure to the input one (if not set explicitly) and records the mode and framerate.
  """
  @spec init_input_structure(
          t(),
          mode(),
          stream_structure(),
          AUTimestampGenerator.framerate() | nil
        ) :: t()
  def init_input_structure(core, mode, input_stream_structure, framerate) do
    %{
      core
      | mode: mode,
        nalu_splitter: NALuSplitter.new(input_stream_structure),
        nalu_parser: NALuParser.new(input_stream_structure),
        input_stream_structure: input_stream_structure,
        output_stream_structure: core.output_stream_structure || input_stream_structure,
        framerate: framerate
    }
  end

  @doc """
  Sets the parser mode (used after flushing on a mode change).
  """
  @spec set_mode(t(), mode()) :: t()
  def set_mode(core, mode), do: %{core | mode: mode}

  @doc """
  Splits and parses a payload into complete access units.

  Applies the pending frame prefix, splits the payload into NAL units, parses them,
  groups them into access units and generates best-effort timestamps if enabled.
  """
  @spec process_buffer(t(), binary(), timestamps()) :: {[AUSplitter.access_unit()], t()}
  def process_buffer(core, payload, {pts, dts} = timestamps) do
    {payload, core} =
      case core.frame_prefix do
        <<>> -> {payload, core}
        prefix -> {prefix <> payload, %{core | frame_prefix: <<>>}}
      end

    is_nalu_aligned = core.mode != :bytestream

    {nalus_payloads, nalu_splitter} =
      NALuSplitter.split(payload, is_nalu_aligned, core.nalu_splitter)

    {nalus, nalu_parser} =
      NALuParser.parse_nalus(core.nalu_parser_mod, nalus_payloads, timestamps, core.nalu_parser)

    is_au_aligned = core.mode == :au_aligned

    {access_units, au_splitter} =
      AUSplitter.split(core.au_splitter_mod, nalus, is_au_aligned, core.au_splitter)

    core = %{
      core
      | nalu_splitter: nalu_splitter,
        nalu_parser: nalu_parser,
        au_splitter: au_splitter,
        previous_buffer_timestamps: {pts || dts, dts || pts}
    }

    maybe_generate_timestamps(access_units, false, core)
  end

  @doc """
  Drains all buffered data into access units. To be used on a mode change or end of stream.
  """
  @spec flush(t()) :: {[AUSplitter.access_unit()], t()}
  def flush(core) do
    {nalus_payloads, nalu_splitter} = NALuSplitter.split(<<>>, true, core.nalu_splitter)

    {nalus, nalu_parser} =
      NALuParser.parse_nalus(
        core.nalu_parser_mod,
        nalus_payloads,
        core.previous_buffer_timestamps,
        core.nalu_parser
      )

    {access_units, au_splitter} =
      AUSplitter.split(core.au_splitter_mod, nalus, true, core.au_splitter)

    core = %{
      core
      | nalu_splitter: nalu_splitter,
        nalu_parser: nalu_parser,
        au_splitter: au_splitter
    }

    maybe_generate_timestamps(access_units, true, core)
  end

  @doc """
  Parses a flat list of raw (unprefixed) parameter-set payloads into NALu structs.
  """
  @spec parse_parameter_sets(t(), [binary()]) :: {[NALu.t()], t()}
  def parse_parameter_sets(core, payloads) do
    {nalus, nalu_parser} =
      NALuParser.parse_nalus(core.nalu_parser_mod, payloads, {nil, nil}, false, core.nalu_parser)

    {nalus, %{core | nalu_parser: nalu_parser}}
  end

  @doc """
  Given a flat list of incoming parameter-set payloads, returns only those that are
  not already cached.
  """
  @spec filter_new_parameter_sets(t(), [binary()]) :: [binary()]
  def filter_new_parameter_sets(core, incoming_payloads) do
    incoming_payloads -- Enum.map(core.cached_parameter_sets, & &1.payload)
  end

  @doc """
  Adds the given parameter-set NALus to the cache, keeping the ones already cached and
  appending only those whose payload is not present yet.
  """
  @spec cache_parameter_sets(t(), [NALu.t()]) :: t()
  def cache_parameter_sets(core, new_parameter_sets) do
    cached_payloads = Enum.map(core.cached_parameter_sets, & &1.payload)

    updated =
      core.cached_parameter_sets ++
        Enum.filter(new_parameter_sets, &(&1.payload not in cached_payloads))

    %{core | cached_parameter_sets: updated}
  end

  @doc """
  Stores the given parameter-set payloads as a frame prefix that will be prepended to
  the next processed buffer, prefixed according to the input stream structure.
  """
  @spec set_frame_prefix(t(), [binary()]) :: t()
  def set_frame_prefix(core, payloads) do
    frame_prefix = NALuParser.prefix_nalus_payloads(payloads, core.input_stream_structure)
    %{core | frame_prefix: frame_prefix}
  end

  @doc """
  Reconciles an access unit's parameter sets for output, given its extracted
  `parameter_sets` and the output policy:

    * `strip?` - the output carries parameter sets out of band (e.g. in a DCR), so they
      are removed from the access unit;
    * otherwise, on a keyframe, the cached parameter sets are repeated (when `repeat?`)
      and duplicates are removed.
  """
  @spec finalize_au_parameter_sets(t(), access_unit(), [NALu.t()],
          strip?: boolean(),
          repeat?: boolean(),
          keyframe?: boolean()
        ) :: access_unit()
  def finalize_au_parameter_sets(core, au, parameter_sets, opts) do
    cond do
      opts[:strip?] ->
        Enum.filter(au, &(&1 not in parameter_sets))

      opts[:keyframe?] ->
        au = if opts[:repeat?], do: core.cached_parameter_sets ++ au, else: au
        Enum.uniq_by(au, & &1.payload)

      true ->
        au
    end
  end

  defguardp is_timestamp_generator_active(core)
            when is_map(core) and core.mode == :bytestream and
                   not is_nil(core.au_timestamp_generator)

  @spec maybe_generate_timestamps([AUSplitter.access_unit()], boolean(), t()) ::
          {[AUSplitter.access_unit()], t()}
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

  @spec get_timestamp_generator(false | AUTimestampGenerator.config(), module()) ::
          {AUTimestampGenerator.state() | nil, AUTimestampGenerator.framerate() | nil}
  defp get_timestamp_generator(false, _module), do: {nil, nil}

  defp get_timestamp_generator(config, module) do
    {AUTimestampGenerator.new(module, config), config.framerate}
  end
end
