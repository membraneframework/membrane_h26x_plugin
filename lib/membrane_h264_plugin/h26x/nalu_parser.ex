defmodule Membrane.H26x.NALuParser do
  @moduledoc """
  A module providing functionality of parsing a stream of binaries, out of which each
  is a payload of a single NAL unit.
  """

  alias Membrane.H26x.{NALu, Parser}
  alias Membrane.H26x.NALuParser.SchemeParser

  @annexb_prefix_code <<0, 0, 0, 1>>

  @typedoc """
  A structure holding the state of the NALu parser.
  """
  @opaque t :: %__MODULE__{
            scheme_parser_state: SchemeParser.t(),
            input_stream_structure: Parser.stream_structure(),
            codec_parser: module()
          }
  @enforce_keys [:input_stream_structure, :codec_parser]
  defstruct @enforce_keys ++
              [
                scheme_parser_state: SchemeParser.new()
              ]

  @doc """
  Returns a structure holding a clear NALu parser state. `input_stream_structure`
  determines the prefixes of input NALU payloads.
  """
  @spec new(module(), Parser.stream_structure()) :: t()
  def new(codec_parser, input_stream_structure \\ :annexb) do
    %__MODULE__{
      codec_parser: codec_parser,
      input_stream_structure: input_stream_structure
    }
  end

  @doc """
  Parses a list of binaries, each representing a single NALu.

  See `parse/3` for details.
  """
  @spec parse_nalus([binary()], NALu.timestamps(), boolean(), t()) :: {[NALu.t()], t()}
  def parse_nalus(nalus_payloads, timestamps \\ {nil, nil}, payload_prefixed? \\ true, state) do
    Enum.map_reduce(nalus_payloads, state, fn nalu_payload, state ->
      parse(nalu_payload, timestamps, payload_prefixed?, state)
    end)
  end

  @doc """
  Parses a binary representing a single NALu and removes it's prefix (if it exists).

  Returns a structure that
  contains parsed fields fetched from that NALu.
  When `payload_prefixed?` is true the input binary is expected to contain one of:
  * prefix defined as the *"Annex B"* of the *"ITU-T Rec. H.264 (01/2012)"*.
  * prefix of size defined in state describing the length of the NALU in bytes, as described in *ISO/IEC 14496-15*.
  """
  @spec parse(binary(), NALu.timestamps(), boolean(), t()) :: {NALu.t(), t()}
  def parse(nalu_payload, timestamps \\ {nil, nil}, payload_prefixed? \\ true, state) do
    {prefix, unprefixed_nalu_payload} =
      if payload_prefixed? do
        unprefix_nalu_payload(nalu_payload, state.input_stream_structure)
      else
        {<<>>, nalu_payload}
      end

    {nalu_header, nalu_body} =
      state.codec_parser.get_nalu_header_and_body(unprefixed_nalu_payload)

    new_scheme_parser_state = SchemeParser.new(state.scheme_parser_state)

    {parsed_fields, scheme_parser_state} =
      state.codec_parser.parse_nalu_header(nalu_header, new_scheme_parser_state)

    type = state.codec_parser.get_nalu_type(parsed_fields.nal_unit_type)

    {nalu, scheme_parser_state} =
      try do
        {parsed_fields, scheme_parser_state} =
          state.codec_parser.parse_proper_nalu_type(nalu_body, type, scheme_parser_state)

        {%NALu{
           parsed_fields: parsed_fields,
           type: type,
           status: :valid,
           stripped_prefix: prefix,
           payload: unprefixed_nalu_payload,
           timestamps: timestamps
         }, scheme_parser_state}
      catch
        "Cannot load information from SPS" ->
          {%NALu{
             parsed_fields: parsed_fields,
             type: type,
             status: :error,
             stripped_prefix: prefix,
             payload: unprefixed_nalu_payload,
             timestamps: timestamps
           }, scheme_parser_state}
      end

    state = %{state | scheme_parser_state: scheme_parser_state}

    {nalu, state}
  end

  @doc """
  Returns payload of the NALu with appropriate prefix generated based on output stream
  structure and prefix length.
  """
  @spec get_prefixed_nalu_payload(NALu.t(), Parser.stream_structure(), boolean()) :: binary()
  def get_prefixed_nalu_payload(nalu, output_stream_structure, stable_prefixing? \\ true) do
    case {output_stream_structure, stable_prefixing?} do
      {:annexb, true} ->
        case nalu.stripped_prefix do
          <<0, 0, 1>> -> <<0, 0, 1, nalu.payload::binary>>
          <<0, 0, 0, 1>> -> <<0, 0, 0, 1, nalu.payload::binary>>
          _prefix -> @annexb_prefix_code <> nalu.payload
        end

      {:annexb, false} ->
        @annexb_prefix_code <> nalu.payload

      {{_codec_tag, nalu_length_size}, _stable_prefixing?} ->
        <<byte_size(nalu.payload)::integer-size(nalu_length_size)-unit(8), nalu.payload::binary>>
    end
  end

  @spec unprefix_nalu_payload(binary(), Parser.stream_structure()) ::
          {stripped_prefix :: binary(), payload :: binary()}
  defp unprefix_nalu_payload(nalu_payload, :annexb) do
    case nalu_payload do
      <<0, 0, 1, rest::binary>> -> {<<0, 0, 1>>, rest}
      <<0, 0, 0, 1, rest::binary>> -> {<<0, 0, 0, 1>>, rest}
    end
  end

  defp unprefix_nalu_payload(nalu_payload, {_codec_tag, nalu_length_size}) do
    <<nalu_length::integer-size(nalu_length_size)-unit(8), rest::binary>> = nalu_payload

    {<<nalu_length::integer-size(nalu_length_size)-unit(8)>>, rest}
  end

  @spec prefix_nalus_payloads([binary()], Parser.stream_structure()) :: binary()
  def prefix_nalus_payloads(nalus, :annexb) do
    Enum.join([<<>> | nalus], @annexb_prefix_code)
  end

  def prefix_nalus_payloads(nalus, {_codec_tag, nalu_length_size}) do
    Enum.map_join(nalus, fn nalu ->
      <<byte_size(nalu)::integer-size(nalu_length_size)-unit(8), nalu::binary>>
    end)
  end
end
