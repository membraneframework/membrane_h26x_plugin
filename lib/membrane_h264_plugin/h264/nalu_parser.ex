defmodule Membrane.H264.NALuParser do
  @moduledoc """
  This module is an extension to `Membrane.H26x.NALuParser` and contains
  H264 specific functions.
  """

  use Membrane.H26x.NALuParser

  alias Membrane.H264.NALuParser.Schemes
  alias Membrane.H264.NALuTypes
  alias Membrane.H26x.NALuParser.SchemeParser

  @impl true
  def get_nalu_header_and_body(<<nalu_header::binary-size(1), nalu_body::binary>>),
    do: {nalu_header, nalu_body}

  @impl true
  def parse_nalu_header(nalu_header, state) do
    SchemeParser.parse_with_scheme(nalu_header, Schemes.NALuHeader, state)
  end

  @impl true
  def get_nalu_type(nal_unit_type), do: NALuTypes.get_type(nal_unit_type)

  @impl true
  def parse_proper_nalu_type(nalu_body, nalu_type, state) do
    try do
      {parsed_fields, state} = do_parse_proper_nalu_type(nalu_body, nalu_type, state)
      {:ok, parsed_fields, state}
    catch
      "Cannot load information from SPS" ->
        {:error, state}
    end
  end

  defp do_parse_proper_nalu_type(nalu_body, nalu_type, state) do
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
