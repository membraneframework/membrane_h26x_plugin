defmodule Membrane.H264.Parser.NALuParser do
  @moduledoc """
  A module providing functionality of parsing a stream of binaries, out of which each
  is a payload of a single NAL unit.
  """

  alias Membrane.H264.Parser
  alias Membrane.H264.Parser.{NALu, NALuTypes}
  alias Membrane.H264.Parser.NALuParser.{SchemeParser, Schemes}

  @annexb_prefix_code <<0, 0, 0, 1>>

  @typedoc """
  A structure holding the state of the NALu parser.
  """
  @opaque t :: %__MODULE__{
            scheme_parser_state: SchemeParser.t(),
            input_stream_structure: Parser.stream_structure(),
            output_stream_structure: Parser.stream_structure(),
            stable_reprefixing?: boolean()
          }
  @enforce_keys [:input_stream_structure, :output_stream_structure]
  defstruct @enforce_keys ++
              [scheme_parser_state: SchemeParser.new(), stable_reprefixing?: true]

  @doc """
  Returns a structure holding a clear NALu parser state. `input_stream_structure` and
  `output_stream_structure` determine the prefixes of input and output NALU payloads.
  If `stable_prefixing?` is set to true, then if input and output stream structures are the same
  the prefix will not change. If `stable_prefixing?` is set to false, then a Annex B prefix code
  0x000001 could be replaced by 0x00000001.
  """
  @spec new(
          Parser.stream_structure(),
          Parser.stream_structure(),
          boolean()
        ) :: t()
  def new(
        input_stream_structure \\ :annexb,
        output_stream_structure \\ :annexb,
        stable_reprefixing? \\ true
      ) do
    %__MODULE__{
      input_stream_structure: input_stream_structure,
      output_stream_structure: output_stream_structure,
      stable_reprefixing?: stable_reprefixing?
    }
  end

  @doc """
  Parses a binary representing a single NALu and changes it's prefix to the one specified in
  `output_stream_structure`. In

  Returns a structure that
  contains parsed fields fetched from that NALu.
  When `payload_prefixed?` is true the input binary is expected to contain one of:
  * prefix defined as the *"Annex B"* of the *"ITU-T Rec. H.264 (01/2012)"*.
  * prefix of size defined in state describing the length of the NALU in bytes, as described in *ISO/IEC 14496-15*.
  """
  @spec parse(binary(), t(), boolean()) :: {NALu.t(), t()}
  def parse(nalu_payload, state, payload_prefixed? \\ true) do
    {initial_prefix_length, unprefixed_nalu_payload} =
      if payload_prefixed? do
        unprefix_nalu_payload(nalu_payload, state.input_stream_structure)
      else
        {0, nalu_payload}
      end

    <<nalu_header::binary-size(1), nalu_body::binary>> = unprefixed_nalu_payload

    new_scheme_parser_state = SchemeParser.new(state.scheme_parser_state)

    {parsed_fields, scheme_parser_state} =
      SchemeParser.parse_with_scheme(
        nalu_header,
        Schemes.NALuHeader,
        new_scheme_parser_state
      )

    type = NALuTypes.get_type(parsed_fields.nal_unit_type)

    {prefix_length, reprefixed_nalu_payload} =
      case {state.input_stream_structure, state.output_stream_structure} do
        {type, type} when state.stable_reprefixing? and payload_prefixed? ->
          {initial_prefix_length, nalu_payload}

        {_, :annexb} ->
          {4, @annexb_prefix_code <> unprefixed_nalu_payload}

        {_, {_avc, nalu_length_size}} ->
          {nalu_length_size,
           <<byte_size(unprefixed_nalu_payload)::integer-size(nalu_length_size)-unit(8),
             unprefixed_nalu_payload::binary>>}
      end

    {nalu, scheme_parser_state} =
      try do
        {parsed_fields, scheme_parser_state} =
          parse_proper_nalu_type(nalu_body, scheme_parser_state, type)

        {%NALu{
           parsed_fields: parsed_fields,
           type: type,
           status: :valid,
           prefix_length: prefix_length,
           payload: reprefixed_nalu_payload
         }, scheme_parser_state}
      catch
        "Cannot load information from SPS" ->
          {%NALu{
             parsed_fields: parsed_fields,
             type: type,
             status: :error,
             prefix_length: prefix_length,
             payload: reprefixed_nalu_payload
           }, scheme_parser_state}
      end

    state = %{state | scheme_parser_state: scheme_parser_state}

    {nalu, state}
  end

  @doc """
  Removes the prefix specified in the stream structure from the passed binary and returns
  the unprefixed payload with the removed prefix's length.
  """
  @spec unprefix_nalu_payload(binary(), Parser.stream_structure()) :: {pos_integer(), binary()}
  def unprefix_nalu_payload(nalu_payload, :annexb) do
    case nalu_payload do
      <<0, 0, 1, rest::binary>> -> {3, rest}
      <<0, 0, 0, 1, rest::binary>> -> {4, rest}
    end
  end

  def unprefix_nalu_payload(nalu_payload, {_avc, nalu_length_size}) do
    <<_nalu_length::integer-size(nalu_length_size)-unit(8), rest::binary>> = nalu_payload

    {nalu_length_size, rest}
  end

  defp parse_proper_nalu_type(payload, state, type) do
    case type do
      :sps ->
        SchemeParser.parse_with_scheme(payload, Schemes.SPS, state)

      :pps ->
        SchemeParser.parse_with_scheme(payload, Schemes.PPS, state)

      :idr ->
        SchemeParser.parse_with_scheme(payload, Schemes.Slice, state)

      :non_idr ->
        SchemeParser.parse_with_scheme(payload, Schemes.Slice, state)

      _unknown_nalu_type ->
        {%{}, state}
    end
  end
end
