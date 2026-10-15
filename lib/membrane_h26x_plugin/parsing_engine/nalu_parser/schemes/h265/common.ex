defmodule Membrane.H265.NALuParser.Schemes.Common do
  @moduledoc false

  # Quoted schemes of the syntax structures shared between (or nested in) the NALu
  # schemes, spliced into them at compile time.

  @spec profile_tier_level() :: Macro.t()
  def profile_tier_level() do
    quote do
      [
        field: {:profile_space, :u2},
        field: {:tier_flag, :u1},
        field: {:profile_idc, :u5},
        field: {:profile_compatibility_flag, :u32},
        field: {:progressive_source_flag, :u1},
        field: {:interlaced_source_flag, :u1},
        field: {:non_packed_constraint_flag, :u1},
        field: {:frame_only_constraint_flag, :u1},
        field: {:reserved_zero_44bits, :u44},
        field: {:level_idc, :u8},
        for: {
          [iterator: :i, from: 0, to: {&(&1 - 1), [:max_sub_layers_minus1]}],
          field: {:sub_layer_profile_present_flag, :u1},
          field: {:sub_layer_level_present_flag, :u1}
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

  @spec vui_parameters() :: Macro.t()
  def vui_parameters() do
    quote do
      [
        field: {:aspect_ratio_info_present_flag, :u1},
        if: {
          {&(&1 == 1), [:aspect_ratio_info_present_flag]},
          field: {:aspect_ratio_idc, :u8},
          if: {
            {&(&1 == 255), [:aspect_ratio_idc]},
            field: {:sar_width, :u16}, field: {:sar_height, :u16}
          }
        },
        field: {:overscan_info_present_flag, :u1},
        if: {
          {&(&1 == 1), [:overscan_info_present_flag]},
          field: {:overscan_appropriate_flag, :u1}
        },
        field: {:video_signal_type_present_flag, :u1},
        if: {
          {&(&1 == 1), [:video_signal_type_present_flag]},
          field: {:video_format, :u3},
          field: {:video_full_range_flag, :u1},
          field: {:colour_description_present_flag, :u1},
          if: {
            {&(&1 == 1), [:colour_description_present_flag]},
            field: {:colour_primaries, :u8},
            field: {:transfer_characteristics, :u8},
            field: {:matrix_coeffs, :u8}
          }
        },
        field: {:chroma_loc_info_present_flag, :u1},
        if: {
          {&(&1 == 1), [:chroma_loc_info_present_flag]},
          field: {:chroma_sample_loc_type_top_field, :ue},
          field: {:chroma_sample_loc_type_bottom_field, :ue}
        },
        field: {:neutral_chroma_indication_flag, :u1},
        field: {:field_seq_flag, :u1},
        field: {:frame_field_info_present_flag, :u1},
        field: {:default_display_window_flag, :u1},
        if: {
          {&(&1 == 1), [:default_display_window_flag]},
          field: {:def_disp_win_left_offset, :ue},
          field: {:def_disp_win_right_offset, :ue},
          field: {:def_disp_win_top_offset, :ue},
          field: {:def_disp_win_bottom_offset, :ue}
        },
        field: {:vui_timing_info_present_flag, :u1},
        if: {
          {&(&1 == 1), [:vui_timing_info_present_flag]},
          field: {:num_units_in_tick, :u32},
          field: {:time_scale, :u32},
          field: {:poc_proportional_to_timing_flag, :u1},
          if: {
            {&(&1 == 1), [:poc_proportional_to_timing_flag]},
            field: {:num_ticks_poc_diff_one_minus1, :ue}
          },
          field: {:hrd_parameters_present_flag, :u1}
        }
      ]
    end
  end
end
