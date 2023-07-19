defmodule Membrane.H264.Parser.NALuParser do
  @moduledoc """
  A module providing functionality of parsing a stream of binaries, out of which each
  is a payload of a single NAL unit.
  """
  alias Membrane.H264.Parser.{NALu, NALuTypes}
  alias Membrane.H264.Parser.NALuParser.SchemeParser
  alias Membrane.H264.Parser.NALuParser.Schemes

  @typedoc """
  A structure holding the state of the NALu parser.
  """
  @opaque t :: %__MODULE__{
            scheme_parser_state: SchemeParser.t(),
            stream_type: :annexb | {:avcc, nalu_length_size :: pos_integer()}
          }
  @enforce_keys [:stream_type]
  defstruct @enforce_keys ++ [scheme_parser_state: SchemeParser.new()]

  @doc """
  Returns a structure holding a clear NALu parser state.
  """
  @spec new(:annexb | {:avcc, nalu_length_size :: pos_integer()}) :: t()
  def new(stream_type \\ :annexb), do: %__MODULE__{stream_type: stream_type}

  @doc """
  Parses a binary representing a single NALu.

  Returns a structure that
  contains parsed fields fetched from that NALu.
  The input binary is expected to contain the prefix, defined as in
  the *"Annex B"* of the *"ITU-T Rec. H.264 (01/2012)"*.
  """
  @spec parse(binary(), t()) :: {NALu.t(), t()}
  def parse(nalu_payload, state) do
    {prefix_length, nalu_payload_without_prefix} =
      case state.stream_type do
        :annexb ->
          case nalu_payload do
            <<0, 0, 1, rest::binary>> -> {3, rest}
            <<0, 0, 0, 1, rest::binary>> -> {4, rest}
          end

        {:avcc, nalu_length_size} ->
          <<_nalu_length::integer-size(nalu_length_size)-unit(8), rest::binary>> = nalu_payload

          {nalu_length_size, rest}
      end

    <<nalu_header::binary-size(1), nalu_body::binary>> = nalu_payload_without_prefix

    new_scheme_parser_state = SchemeParser.new(state.scheme_parser_state)

    {parsed_fields, scheme_parser_state} =
      SchemeParser.parse_with_scheme(
        nalu_header,
        Schemes.NALuHeader,
        new_scheme_parser_state
      )

    type = NALuTypes.get_type(parsed_fields.nal_unit_type)

    {nalu, scheme_parser_state} =
      try do
        {parsed_fields, scheme_parser_state} =
          parse_proper_nalu_type(nalu_body, scheme_parser_state, type)

        {%NALu{
           parsed_fields: parsed_fields,
           type: type,
           status: :valid,
           prefix_length: prefix_length,
           payload: nalu_payload
         }, scheme_parser_state}
      catch
        "Cannot load information from SPS" ->
          {%NALu{
             parsed_fields: parsed_fields,
             type: type,
             status: :error,
             prefix_length: prefix_length,
             payload: nalu_payload
           }, scheme_parser_state}
      end

    state = %{state | scheme_parser_state: scheme_parser_state}

    {nalu, state}
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
