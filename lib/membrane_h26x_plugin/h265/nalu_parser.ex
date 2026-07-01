defmodule Membrane.H265.NALuParser do
  @moduledoc """
  This module is an extension to `Membrane.H26x.NALuParser` and contains
  H265 specific functions.
  """

  @behaviour Membrane.H26x.NALuParser

  require Membrane.H265.NALuTypes
  require Membrane.Logger

  alias Membrane.H265.NALuParser.Schemes
  alias Membrane.H265.NALuTypes
  alias Membrane.H26x.{NALu, NALuParser}
  alias Membrane.H26x.NALuParser.SchemeParser

  defdelegate new(input_stream_structure \\ :annexb), to: NALuParser

  @spec parse_nalus([binary()], NALu.timestamps(), boolean(), NALuParser.t()) ::
          {[NALu.t()], NALuParser.t()}
  def parse_nalus(nalus_payloads, timestamps \\ {nil, nil}, payload_prefixed? \\ true, state),
    do: NALuParser.parse_nalus(__MODULE__, nalus_payloads, timestamps, payload_prefixed?, state)

  defdelegate get_prefixed_nalu_payload(nalu, output_stream_structure, stable_prefixing? \\ true),
    to: NALuParser

  defdelegate prefix_nalus_payloads(nalus, input_stream_structure), to: NALuParser

  @impl true
  def get_nalu_header_and_body(<<nalu_header::binary-size(2), nalu_body::binary>>),
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
  def parse_proper_nalu_type(nalu_body, nalu_type, state) do
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
          {:ok, SchemeParser.get_local_state(state), state}
        end
    end
  rescue
    error ->
      Membrane.Logger.warning(
        "Failed to parse a #{nalu_type} NALu, marking it as erroneous: #{inspect(error)}"
      )

      {:error, state}
  end
end
