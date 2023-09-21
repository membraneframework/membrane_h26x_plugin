defmodule Membrane.H26x.Common.NALuParser do
  @moduledoc """
  A module providing functionality of parsing a stream of binaries, out of which each
  is a payload of a single NAL unit.
  """

  alias Membrane.H264.Parser.NALuParser.Schemes, as: AVCSchemes
  alias Membrane.H265.Parser.NALuParser.Schemes, as: HEVCSchemes

  alias Membrane.H264.Parser.NALuTypes, as: AVCNALuTypes
  alias Membrane.H265.Parser.NALuTypes, as: HEVCNALuTypes

  alias Membrane.H26x.Common.{NALu, Parser}
  alias Membrane.H26x.Common.NALuParser.SchemeParser

  @annexb_prefix_code <<0, 0, 0, 1>>

  @typedoc """
  A structure holding the state of the NALu parser.
  """
  @opaque t :: %__MODULE__{
            scheme_parser_state: SchemeParser.t(),
            input_stream_structure: Parser.stream_structure(),
            encoding: Parser.encoding(),
            nal_header_size: non_neg_integer(),
            nalu_types_module: module(),
            schemes_module: module()
          }
  @enforce_keys [:input_stream_structure, :encoding]
  defstruct @enforce_keys ++
              [
                scheme_parser_state: SchemeParser.new(),
                nal_header_size: 1,
                nalu_types_module: nil,
                schemes_module: nil
              ]

  @doc """
  Returns a structure holding a clear NALu parser state. `input_stream_structure`
  determines the prefixes of input NALU payloads.
  """
  @spec new(Parser.encoding(), Parser.stream_structure()) :: t()
  def new(encoding \\ :h264, input_stream_structure \\ :annexb)

  def new(:h264, input_stream_structure) do
    %__MODULE__{
      encoding: :h264,
      input_stream_structure: input_stream_structure,
      nal_header_size: 1,
      nalu_types_module: Membrane.H264.Parser.NALuTypes,
      schemes_module: Membrane.H264.Parser.NALuParser.Schemes
    }
  end

  def new(:h265, input_stream_structure) do
    %__MODULE__{
      encoding: :h265,
      input_stream_structure: input_stream_structure,
      nal_header_size: 2,
      nalu_types_module: Membrane.H265.Parser.NALuTypes,
      schemes_module: Membrane.H265.Parser.NALuParser.Schemes
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
        {0, nalu_payload}
      end

    <<nalu_header::binary-size(state.nal_header_size), nalu_body::binary>> =
      unprefixed_nalu_payload

    new_scheme_parser_state = SchemeParser.new(state.scheme_parser_state)

    {parsed_fields, scheme_parser_state} =
      parse_nalu_header(state.encoding, nalu_header, new_scheme_parser_state)

    type = get_nalu_type(state.encoding, parsed_fields.nal_unit_type)

    {nalu, scheme_parser_state} =
      try do
        {parsed_fields, scheme_parser_state} =
          parse_proper_nalu_type(state.encoding, nalu_body, scheme_parser_state, type)

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

      {{_avc, nalu_length_size}, _stable_prefixing?} ->
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

  defp unprefix_nalu_payload(nalu_payload, {_avc, nalu_length_size}) do
    <<nalu_length::integer-size(nalu_length_size)-unit(8), rest::binary>> = nalu_payload

    {<<nalu_length::integer-size(nalu_length_size)-unit(8)>>, rest}
  end

  @spec prefix_nalus_payloads([binary()], Parser.stream_structure()) :: binary()
  def prefix_nalus_payloads(nalus, :annexb) do
    Enum.join([<<>> | nalus], @annexb_prefix_code)
  end

  def prefix_nalus_payloads(nalus, {_avc, nalu_length_size}) do
    Enum.map_join(nalus, fn nalu ->
      <<byte_size(nalu)::integer-size(nalu_length_size)-unit(8), nalu::binary>>
    end)
  end

  defp parse_nalu_header(:h264, nalu_header, state) do
    SchemeParser.parse_with_scheme(nalu_header, AVCSchemes.NALuHeader, state)
  end

  defp parse_nalu_header(:h265, nalu_header, state) do
    SchemeParser.parse_with_scheme(nalu_header, HEVCSchemes.NALuHeader, state)
  end

  defp get_nalu_type(:h264, nal_unit_type), do: AVCNALuTypes.get_type(nal_unit_type)
  defp get_nalu_type(:h265, nal_unit_type), do: HEVCNALuTypes.get_type(nal_unit_type)

  defp parse_proper_nalu_type(:h264, payload, state, type) do
    case type do
      :sps ->
        SchemeParser.parse_with_scheme(payload, AVCSchemes.SPS, state)

      :pps ->
        SchemeParser.parse_with_scheme(payload, AVCSchemes.PPS, state)

      :idr ->
        SchemeParser.parse_with_scheme(payload, AVCSchemes.Slice, state)

      :non_idr ->
        SchemeParser.parse_with_scheme(payload, AVCSchemes.Slice, state)

      _unknown_nalu_type ->
        {%{}, state}
    end
  end

  defp parse_proper_nalu_type(:h265, payload, state, type) do
    # delete prevention emulation 3 bytes
    payload = :binary.split(payload, <<0, 0, 3>>, [:global]) |> Enum.join(<<0, 0>>)

    case type do
      :vps ->
        SchemeParser.parse_with_scheme(payload, HEVCSchemes.VPS, state)

      :sps ->
        SchemeParser.parse_with_scheme(payload, HEVCSchemes.SPS, state)

      :pps ->
        SchemeParser.parse_with_scheme(payload, HEVCSchemes.PPS, state)

      type ->
        if type in HEVCNALuTypes.vcl_nalu_types() do
          SchemeParser.parse_with_scheme(payload, HEVCSchemes.Slice, state)
        else
          {SchemeParser.get_local_state(state), state}
        end
    end
  end
end
