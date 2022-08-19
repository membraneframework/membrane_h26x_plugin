defmodule Membrane.H264.Parser.Schemes.NALu do
  @moduledoc false
  @behaviour Membrane.H264.Parser.Scheme
  alias Membrane.H264.Parser.NALuPayload
  alias Membrane.H264.Parser.Schemes

  @impl true
  def scheme(),
    do: [
      field: {:forbidden_zero_bit, :u1},
      field: {:nal_ref_idc, :u2},
      field: {:nal_unit_type, :u5},
      execute: &parse_proper_nalu_type(&1, &2, &3)
    ]

  defp parse_proper_nalu_type(payload, state, _iterators) do
    case NALuPayload.nalu_types()[state.__local__.nal_unit_type] do
      :sps ->
        NALuPayload.parse_with_scheme(payload, Schemes.SPS.scheme(), state)

      :pps ->
        NALuPayload.parse_with_scheme(payload, Schemes.PPS.scheme(), state)

      :idr ->
        NALuPayload.parse_with_scheme(payload, Schemes.Slice.scheme(), state)

      :non_idr ->
        NALuPayload.parse_with_scheme(payload, Schemes.Slice.scheme(), state)

      _unknown_nalu_type ->
        {payload, state}
    end
  end
end
