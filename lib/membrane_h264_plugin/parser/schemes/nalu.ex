defmodule Membrane.H264.Parser.Schemes.NALu do
  alias Membrane.H264.Parser.NALuPayload
  alias Membrane.H264.Parser.Schemes

  @nalu_types %{
                0 => :unspecified,
                1 => :non_idr,
                2 => :part_a,
                3 => :part_b,
                4 => :part_c,
                5 => :idr,
                6 => :sei,
                7 => :sps,
                8 => :pps,
                9 => :aud,
                10 => :end_of_seq,
                11 => :end_of_stream,
                12 => :filler_data,
                13 => :sps_extension,
                14 => :prefix_nal_unit,
                15 => :subset_sps,
                (16..18) => :reserved,
                19 => :auxiliary_non_part,
                20 => :extension,
                (21..23) => :reserved,
                (24..31) => :unspecified
              }
              |> Enum.flat_map(fn
                {k, v} when is_integer(k) -> [{k, v}]
                {k, v} -> Enum.map(k, &{&1, v})
              end)
              |> Map.new()

  def nalu_types, do: @nalu_types

  def scheme(),
    do: [
      field: {:forbidden_zero_bit, :u1},
      field: {:nal_ref_idc, :u2},
      field: {:nal_unit_type, :u5},
      execute: &parse_proper_nalu_type(&1, &2, &3)
    ]

  defp parse_proper_nalu_type(payload, state, _prefix) do
    case @nalu_types[state.nal_unit_type] do
      :sps ->
        NALuPayload.parse_with_scheme(payload, Schemes.SPS.scheme(), state)

      :pps ->
        NALuPayload.parse_with_scheme(payload, Schemes.PPS.scheme(), state)

      :idr ->
        NALuPayload.parse_with_scheme(payload, Schemes.Slice.scheme(), state)

      :non_idr ->
        NALuPayload.parse_with_scheme(payload, Schemes.Slice.scheme(), state)

      _ ->
        {payload, state}
    end
  end
end
