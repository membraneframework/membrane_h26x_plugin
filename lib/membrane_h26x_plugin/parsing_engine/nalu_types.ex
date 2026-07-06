defmodule Membrane.H264.NALuTypes do
  @moduledoc """
  The module aggregating the mapping of from `nal_unit_type`
  fields of the NAL unit to the human-friendly name of a NALu type.
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

  @vcl_nalu_types [:idr, :non_idr, :part_a, :part_b, :part_c]

  @typedoc """
  A type representing all the possible human-friendly names of NAL unit types.
  """
  @type nalu_type ::
          unquote(Bunch.Typespec.enum_to_alternative(Map.values(@nalu_types) |> Enum.uniq()))

  @type vcl_nalu_type :: unquote(Bunch.Typespec.enum_to_alternative(@vcl_nalu_types))

  @doc """
  The function which returns the human friendly name of a NALu type
  for a given `nal_unit_type`.

  The mapping is based on: "Table 7-1 – NAL unit type codes, syntax element categories, and NAL unit type classes"
  of the *"ITU-T Rec. H.264 (01/2012)"*
  """
  @spec get_type(non_neg_integer()) :: nalu_type() | nil
  def get_type(nal_unit_type_id) do
    @nalu_types[nal_unit_type_id]
  end

  defguard is_vcl_nalu_type(nalu_type) when nalu_type in @vcl_nalu_types
end

defmodule Membrane.H265.NALuTypes do
  @moduledoc """
  The module aggregating the mapping of `nal_unit_type` fields
  of the NAL unit to the human-friendly name of a NALu type.
  """

  @nalu_types %{
                0 => :trail_n,
                1 => :trail_r,
                2 => :tsa_n,
                3 => :tsa_r,
                4 => :stsa_n,
                5 => :stsa_r,
                6 => :radl_n,
                7 => :radl_r,
                8 => :rasl_n,
                9 => :rasl_r,
                (10..15) => :reserved_non_irap,
                16 => :bla_w_lp,
                17 => :bla_w_radl,
                18 => :bla_n_lp,
                19 => :idr_w_radl,
                20 => :idr_n_lp,
                21 => :cra,
                (22..23) => :reserved_irap,
                (24..31) => :reserved_non_irap,
                32 => :vps,
                33 => :sps,
                34 => :pps,
                35 => :aud,
                36 => :eos,
                37 => :eob,
                38 => :fd,
                39 => :prefix_sei,
                40 => :suffix_sei,
                (41..47) => :reserved_nvcl,
                (48..63) => :unspecified
              }
              |> Enum.flat_map(fn
                {k, v} when is_integer(k) -> [{k, v}]
                {k, v} -> Enum.map(k, &{&1, v})
              end)
              |> Map.new()

  @irap_nalu_types [:bla_w_lp, :bla_w_radl, :bla_n_lp, :idr_w_radl, :idr_n_lp, :cra]
  @vcl_nalu_types [
                    :trail_n,
                    :trail_r,
                    :tsa_n,
                    :tsa_r,
                    :stsa_n,
                    :stsa_r,
                    :radl_n,
                    :radl_r,
                    :rasl_n,
                    :rasl_r,
                    :reserved_non_irap,
                    :reserved_irap
                  ] ++ @irap_nalu_types

  @typedoc """
  A type representing all the possible human-friendly names of NAL unit types.
  """
  @type nalu_type ::
          unquote(Bunch.Typespec.enum_to_alternative(Map.values(@nalu_types) |> Enum.uniq()))

  @doc """
  The function which returns the human friendly name of a NALu type
  for a given `nal_unit_type`.

  The mapping is based on: "Table 7-1 – NAL unit type codes, syntax element categories, and NAL unit type classes"
  of the *"ITU-T Rec. H.265 (08/2021)"*
  """
  @spec get_type(non_neg_integer()) :: atom()
  def get_type(nal_unit_type) do
    @nalu_types[nal_unit_type]
  end

  defguard is_vcl_nalu_type(nalu_type) when nalu_type in @vcl_nalu_types
end
