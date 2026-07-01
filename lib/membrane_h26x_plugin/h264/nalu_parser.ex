defmodule Membrane.H264.NALuParser do
  @moduledoc """
  This module is an extension to `Membrane.H26x.NALuParser` and contains
  H264 specific functions.
  """

  @behaviour Membrane.H26x.NALuParser

  require Membrane.Logger
  require Membrane.H264.NALuTypes, as: NALuTypes

  alias Membrane.H264.NALuParser.Schemes
  alias Membrane.H26x.NALuParser.SchemeParser

  @impl true
  def get_nalu_header_and_body(<<nalu_header::binary-size(1), nalu_body::binary>>),
    do: {nalu_header, nalu_body}

  @impl true
  def parse_nalu_header(nalu_header, state) do
    # Parsing of the header cannot ever fail.
    {:ok, parsed_fields, state} =
      SchemeParser.parse_with_scheme(nalu_header, Schemes.NALuHeader, state)

    {parsed_fields, state}
  end

  @impl true
  def get_nalu_type(nal_unit_type), do: NALuTypes.get_type(nal_unit_type)

  @impl true
  def get_first_vcl_nalu(au), do: Enum.find(au, &NALuTypes.is_vcl_nalu_type(&1.type))

  @impl true
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
        {:ok, %{}, state}
    end
  rescue
    error ->
      Membrane.Logger.warning(
        "Failed to parse a #{nalu_type} NALu, marking it as erroneous: #{inspect(error)}"
      )

      {:error, state}
  end
end
