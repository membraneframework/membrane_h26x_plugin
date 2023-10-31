defmodule Membrane.H265.NALuParser do
  @moduledoc """
  This module is an extension to `Membrane.H26x.NALuParser` and contains
  H265 specific functions.
  """

  use Membrane.H26x.NALuParser

  require Membrane.H265.NALuTypes

  alias Membrane.H265.NALuParser.Schemes
  alias Membrane.H265.NALuTypes
  alias Membrane.H26x.NALuParser.SchemeParser

  @impl true
  def get_nalu_header_and_body(<<nalu_header::binary-size(2), nalu_body::binary>>),
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
      # We throw the scheme parser state since we do need the parsed fields for
      # acess unit splitter even if the parameter sets are not present
      state ->
        {:error, state}
    end
  end

  defp do_parse_proper_nalu_type(nalu_body, nalu_type, state) do
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
