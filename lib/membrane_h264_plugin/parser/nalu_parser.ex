defmodule Membrane.H264.Parser.NALuParser do
  @moduledoc """
  A module providing functionality of parsing a stream of packets, out of which each
  holds a payload of a single NAL unit.

  As a result the parser outputs a stream of parsed NAL units.
  """
  alias Membrane.H264.Parser.{NALu, NALuTypes, SchemeParser}
  alias Membrane.H264.Parser.SchemeParser.Schemes

  @typedoc """
  A structure holding the state of the NALu parser.
  """
  @opaque t :: %__MODULE__{
            scheme_parser_state: SchemeParser.t(),
            has_seen_keyframe?: boolean()
          }
  @enforce_keys [:scheme_parser_state, :has_seen_keyframe?]
  defstruct @enforce_keys

  @doc """
  Returns an structure holding a NALu parser state.
  """
  @spec new() :: t()
  def new(),
    do: %__MODULE__{
      scheme_parser_state: SchemeParser.new(),
      has_seen_keyframe?: false
    }

  @doc """
  Parses a `Membrane.Buffer.t()` with a payload being a part of H264 stream.

  As a result it returns a list of NAL units, along with a part of a payload
  that wasn't completly parsed and the updated state of the NALu parser.
  """
  @spec parse(binary(), t()) :: {NALu.t(), t()}
  def parse(
        nalu_payload,
        state
      ) do
    {prefix_length, nalu_payload} = 
      case nalu_payload do
        <<0, 0, 1, rest::binary>> -> {3, rest}
        <<0, 0, 0, 1, rest::binary>> -> {4, rest}
      end
      
    <<nalu_header, nalu_body::binary>> = nalu_payload  

    new_scheme_parser_state = SchemeParser.new(state.scheme_parser_state)

    {parsed_fields, scheme_parser_state} =
      SchemeParser.parse_with_scheme(
        nalu_header,
        Schemes.NALuHeader.scheme(),
        new_scheme_parser_state
      )

    type = NALuTypes.get_type(parsed_fields.nal_unit_type)

    {nalu, {scheme_parser_state, has_seen_keyframe?}} =
      try do
        {parsed_fields, scheme_parser_state} =
          parse_proper_nalu_type(nalu_body, scheme_parser_state, type)

        status = if type != :non_idr or state.has_seen_keyframe?, do: :valid, else: :error
        has_seen_keyframe? = state.has_seen_keyframe? or type == :idr

        {%NALu{
           parsed_fields: parsed_fields,
           type: type,
           status: status,
           prefix_length: prefix_length,
           payload: nalu_payload
         }, {scheme_parser_state, has_seen_keyframe?}}
      catch
        "Cannot load information from SPS" ->
          {%NALu{
             parsed_fields: parsed_fields,
             type: type,
             status: :error,
             prefix_length: prefix_length,
             payload: nalu_payload
           }, {scheme_parser_state, state.has_seen_keyframe?}}
      end

    state = %__MODULE__{
      scheme_parser_state: scheme_parser_state,
      has_seen_keyframe?: has_seen_keyframe?
    }

    {nalu, state}
  end

  defp parse_proper_nalu_type(payload, state, type) do
    case type do
      :sps ->
        SchemeParser.parse_with_scheme(payload, Schemes.SPS.scheme(), state)

      :pps ->
        SchemeParser.parse_with_scheme(payload, Schemes.PPS.scheme(), state)

      :idr ->
        SchemeParser.parse_with_scheme(payload, Schemes.Slice.scheme(), state)

      :non_idr ->
        SchemeParser.parse_with_scheme(payload, Schemes.Slice.scheme(), state)

      _unknown_nalu_type ->
        {%{}, state}
    end
  end
end
