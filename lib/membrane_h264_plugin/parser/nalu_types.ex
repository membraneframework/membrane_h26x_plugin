defmodule Membrane.H264.Parser.NALuTypes do
  @moduledoc """
  The module aggregating the mapping of from `nal_unit_type` fields of the NAL unit to the
  human-firendly name of a NALu type.
  """
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

  @doc """
  The function which returns the human friendly name of a NALu type for a given `nal_unit_type`.
  The mapping is based on: "Table 7-1 – NAL unit type codes, syntax element categories, and NAL unit type classes" of the "ITU-T Rec. H.264 (01/2012)"
  """
  @spec get_type(non_neg_integer()) :: atom()
  def get_type(nal_unit_type) do
    @nalu_types[nal_unit_type]
  end
end
