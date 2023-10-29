defmodule Membrane.H264.NALuParser do
  @moduledoc """
  This module is an extension to `Membrane.H26x.NALuParser` and contains
  H264 specific functions.
  """

  alias Membrane.H264.NALuParser.Schemes
  alias Membrane.H264.NALuTypes
  alias Membrane.H26x.NALuParser.SchemeParser

  @spec get_nalu_header_and_body(binary()) :: {binary(), binary()}
  def get_nalu_header_and_body(<<nalu_header::binary-size(1), nalu_body::binary>>),
    do: {nalu_header, nalu_body}

  @spec parse_nalu_header(binary(), SchemeParser.t()) :: {map(), SchemeParser.t()}
  def parse_nalu_header(nalu_header, state) do
    SchemeParser.parse_with_scheme(nalu_header, Schemes.NALuHeader, state)
  end

  @spec get_nalu_type(non_neg_integer()) :: NALuTypes.nalu_type()
  def get_nalu_type(nal_unit_type), do: NALuTypes.get_type(nal_unit_type)

  @spec parse_proper_nalu_type(binary(), NALuTypes.nalu_type(), SchemeParser.t()) ::
          {map(), SchemeParser.t()}
  def parse_proper_nalu_type(nalu_body, nalu_type, state) do
    case nalu_type do
      :sps ->
        SchemeParser.parse_with_scheme(nalu_body, Schemes.SPS, state)

      :pps ->
        SchemeParser.parse_with_scheme(nalu_body, Schemes.PPS, state)

      :idr ->
        SchemeParser.parse_with_scheme(nalu_body, Schemes.Slice, state)

      :non_idr ->
        SchemeParser.parse_with_scheme(nalu_body, Schemes.Slice, state)

      _unknown_nalu_type ->
        {%{}, state}
    end
  end
end
