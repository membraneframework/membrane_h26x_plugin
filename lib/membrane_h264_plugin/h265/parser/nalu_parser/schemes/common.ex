defmodule Membrane.H265.Parser.NALuParser.Schemes.Common do
  @moduledoc false

  @spec profile_tier_level() :: Scheme.t()
  def profile_tier_level() do
    [
      field: {:profile_space, :u2},
      field: {:tier_flag, :u1},
      field: {:profile_idc, :u5},
      field: {:profile_compatibility_flag, :u32},
      field: {:progressive_source_flag, :u1},
      field: {:interlaced_source_flag, :u1},
      field: {:non_packed_constraint_flag, :u1},
      field: {:frame_only_constraint_flag, :u1},
      field: {:reserved_zero_44bits, :u44}
    ] ++ level_fields()
  end

  defp level_fields() do
    [
      field: {:level_idc, :u8},
      for: {
        [iterator: :i, from: 0, to: {&(&1 - 1), [:max_sub_layers_minus1]}],
        field: {:sub_layer_profile_present_flag, :u1}, field: {:sub_layer_level_present_flag, :u1}
      },
      if: {
        {&(&1 > 0), [:max_sub_layers_minus1]},
        for: {
          [iterator: :i, from: {& &1, [:max_sub_layers_minus1]}, to: 7],
          field: {:reserved_zero_2bits, :u2}
        }
      },
      for: {
        [iterator: :i, from: 0, to: {&(&1 - 1), [:max_sub_layers_minus1]}],
        if: {
          {&(&1[&2] == 1), [:sub_layer_profile_present_flag, :i]},
          field: {:sub_layer_profile_space, :u2},
          field: {:sub_layer_tier_flag, :u1},
          field: {:sub_layer_profile_idc, :u5},
          for: {
            [iterator: :j, from: 0, to: 31],
            field: {:sub_layer_profile_compatibility_flag, :u1}
          },
          field: {:sub_layer_progressive_source_flag, :u1},
          field: {:sub_layer_interlaced_source_flag, :u1},
          field: {:sub_layer_non_packed_constraint_flag, :u1},
          field: {:sub_layer_frame_only_constraint_flag, :u1},
          field: {:sub_layer_reserved_zero_44bits, :u44}
        },
        if: {
          {&(&1[&2] == 1), [:sub_layer_level_present_flag, :i]},
          field: {:sub_layer_level_idc, :u8}
        }
      }
    ]
  end
end
