defmodule Membrane.H265.NALuParser do
  @moduledoc """
  This module is an extension to `Membrane.H26x.NALuParser` and contains
  H265 specific functions.
  """

  require Membrane.H265.NALuTypes

  alias Membrane.H265.NALuParser.Schemes
  alias Membrane.H265.NALuTypes
  alias Membrane.H26x.NALuParser.SchemeParser

  @spec get_nalu_header_and_body(binary()) :: {binary(), binary()}
  def get_nalu_header_and_body(<<nalu_header::binary-size(2), nalu_body::binary>>),
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
    # delete prevention emulation 3 bytes
    nalu_body = :binary.split(nalu_body, <<0, 0, 3>>, [:global]) |> Enum.join(<<0, 0>>)

    case nalu_type do
      :vps ->
        SchemeParser.parse_with_scheme(nalu_body, Schemes.VPS, state)

      :sps ->
        SchemeParser.parse_with_scheme(nalu_body, Schemes.SPS, state)

      :pps ->
        SchemeParser.parse_with_scheme(nalu_body, Schemes.PPS, state)

      type ->
        if NALuTypes.is_vcl_nalu_type(type) do
          SchemeParser.parse_with_scheme(nalu_body, Schemes.Slice, state)
        else
          {SchemeParser.get_local_state(state), state}
        end
    end
  end
end
