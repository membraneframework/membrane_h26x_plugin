defmodule Membrane.H264.Parser.Schemes.SPS do
  def scheme, do: [
    field: {:forbidden_zero_bit, :u1},
    field: {:nal_ref_idc, :u2},
    field: {:nal_unit_type, :u5},
    field: {:profile_idc, :u8},
    field: {:constraint_set0, :u1},
    field: {:constraint_set1, :u1},
    field: {:constraint_set2, :u1},
    field: {:constraint_set3, :u1},
    field: {:constraint_set4, :u1},
    field: {:constraint_set5, :u1},
    field: {:reserved_zero_2bits, :u2},
    field: {:level_idc, :u8},
    field: {:seq_parameter_set_id, :ue},
    if: { {fn profile_idc -> profile_idc in [100, 110, 122, 244, 44, 83, 86, 118, 128] end, [:profile_idc]},
      field: {:chroma_format_idc, :ue},
      if: { {fn chroma_format_idc -> chroma_format_idc==3 end, [:chroma_format_idc] },
       field: {:separate_colour_plane_flag, :u1},
      },
      field: {:bit_depth_luma_minus8, :ue},
      field: {:bit_depth_chroma_minus8, :ue},
      field: {:qpprime_y_zero_transform_bypass_flag, :u1},
      field: {:seq_scaling_matrix_present_flag, :u1},
      if: { {fn seq_scaling_matrix_present_flag -> seq_scaling_matrix_present_flag==1 end, [:seq_scaling_matrix_present_flag]},
        for: {{:i, fn chroma_format_idc -> if chroma_format_idc !=3, do: 8, else: 12 end, [:chroma_format_idc]},
          field: {:seq_scaling_list_present, :u1},
          if: { {fn seq_scaling_list_present_flag -> seq_scaling_list_present_flag==1 end, [:seq_scaling_list_present_flag]},
            if: { {fn i -> i<6 end, [:i]},
              execute: fn payload, state, prefix -> scaling_list(payload, state, prefix, 16) end
            },
            if: { {fn i -> i>=6 end, [:i]},
              execute: fn payload, state, prefix -> scaling_list(payload, state, prefix, 64) end
            }
          },
        }
      },
    },
    field: {:log2_max_frame_num_minus4, :ue},
    field: {:pic_order_cnt_type, :ue},
    if: { {fn pic_order_cnt_type ->pic_order_cnt_type == 0 end, [:pic_order_cnt_type] },
      field: {:log2_max_pic_order_cnt_lsb_minus4, :ue},
    },
    if: { {fn pic_order_cnt_type ->pic_order_cnt_type == 1 end, [:pic_order_cnt_type] },
      field: {:delta_pic_order_always_zero_flag, :u1},
      field: {:offset_for_non_ref_pic, :se},
      field: {:offset_for_top_to_bottom_field, :se},
      field: {:num_ref_frames_in_pic_order_cnt_cycle, :se},
      for: {{:i, fn num_ref_frames_in_pic_order_cnt_cycle -> num_ref_frames_in_pic_order_cnt_cycle end, [:num_ref_frames_in_pic_order_cnt_cycle]},
        field: {:offset_for_ref_frame, :se},
      }
    },
    field: {:max_num_ref_frames, :ue},
    field: {:gaps_in_frame_num_value_allowed_flag, :u1},
    field: {:pic_width_in_mbs_minus1, :ue},
    field: {:pic_height_in_map_units_minus1, :ue},
    field: {:frame_mbs_only_flag, :u1},
    if: { {fn frame_mbs_only_flag -> frame_mbs_only_flag != 1 end, [:frame_mbs_only_flag] },
      field: {:mb_adaptive_frame_field_flag, :u1},
    },
    field: {:direct_8x8_inference_flag, :u1},
    field: {:frame_cropping_flag, :u1},
    if: { {fn frame_cropping_flag ->frame_cropping_flag == 1 end, [:frame_cropping_flag] },
      field: {:frame_crop_left_offset, :ue},
      field: {:frame_crop_right_offset, :ue},
      field: {:frame_crop_top_offset, :ue},
      field: {:frame_crop_bottom_offset, :ue},
    },
    field: {:vui_parameters_present_flag, :u1},
    if: { {fn vui_parameters_present_flag ->vui_parameters_present_flag == 1 end, [:vui_parameters_present_flag] },
      []# vui_parameters()
    }
  ]

  def vui_parameters, do: [
    field: {:aspect_ratio_present_flag, :u1},
    if: { {fn aspect_ratio_present_flag -> aspect_ratio_present_flag == 1 end, [:aspect_ratio_present_flag] },
      field: {:aspect_ratio_idc, :u8},
      if: { {fn aspect_ratio_idc -> aspect_ratio_idc == 255 end, [:aspect_ratio_idc]},
        field: {:sar_width, :u16},
        field: {:sar_height, :u16},
      }
    },
    field: {:overscan_info_present_flag, :u1},
    if: { {fn overscan_info_present_flag -> overscan_info_present_flag==1 end, [:overscan_info_present_flag]},
      field: {:overscan_appropriate_flag, :u1},
    },
    field: {:video_signal_type_present_flag, :u1},
    if: { {fn video_signal_type_present_flag -> video_signal_type_present_flag==1 end, [:video_signal_type_present_flag]},
      field: {:video_format, :u3},
      field: {:video_full_range_flag, :u1},
      field: {:colour_description_present_flag, :u1},
      if: { {fn colour_description_present_flag -> colour_description_present_flag==1 end, [:colour_description_present_flag]},
        field: {:colour_primaries, :u8},
        field: {:transfer_characteristics, :u8},
        field: {:matrix_coefficients, :u8},
      },
    },
    field: {:chroma_loc_info_present_flag, :u1},
    if: { {fn chroma_loc_info_present_flag -> chroma_loc_info_present_flag==1 end, [:chroma_loc_info_present_flag]},
      field: {:chroma_sample_loc_type_top_field, :ue},
      field: {:chroma_sample_loc_type_bottom_field, :ue},
    },
    field: {:timing_info_present_flag, :u1},
    if: { {fn timing_info_present_flag -> timing_info_present_flag==1 end, [:timing_info_present_flag]},
      field: {:num_units_in_tick, :u32},
      field: {:time_scale, :u32},
      field: {:fixed_frame_rate_flag, :u1},
    },
    field: {:nal_hrd_parameters_present_flag, :u1},
    if: { {fn nal_hrd_parameters_present_flag -> nal_hrd_parameters_present_flag==1 end, [:nal_hrd_parameters_present_flag]},
      hrd_parameters()
    },
    field: {:vcl_hrd_parameters_present_flag, :u1},
    if: { {fn vcl_hrd_parameters_present_flag -> vcl_hrd_parameters_present_flag==1 end, [:vcl_hrd_parameters_present_flag]},
      hrd_parameters()
    },
    if: { {fn nal_hrd_parameters_present_flag, vcl_hrd_parameters_present_flag -> nal_hrd_parameters_present_flag==1 or vcl_hrd_parameters_present_flag==1 end, [:nal_hrd_parameters_present_flag, :vcl_hrd_parameters_present_flag]},
      field: {:low_delay_hrd_flag, :u1},
    },
    field: {:pic_struct_present_flag, :u1},
    field: {:bitstream_restriction_flag, :u1},
    if: { {fn bitstream_restriction_flag  -> bitstream_restriction_flag==1 end, [:bitstream_restriction_flag]},
      field: {:motion_vectors_over_pic_boundaries_flag, :u1},
      field: {:max_bytes_per_pic_denom, :ue},
      field: {:max_bits_per_mb_denom, :ue},
      field: {:log2_max_mv_length_horizontal, :ue},
      field: {:log2_max_mv_length_vertical, :ue},
      field: {:max_num_reorder_frames, :ue},
      field: {:max_dec_frame_buffering, :ue},
    },
  ]


  def hrd_parameters(), do: [
    field: {:cpb_cnt_minus1, :ue},
    field: {:bit_rate_scale, :u4},
    field: {:cpb_size_scale, :u4},
    for:  {{:schedSeiIdx, fn cpb_cnt_minus1->cpb_cnt_minus1+1 end, [:cpb_cnt_minus1] },
      field: {:bit_rate_value_minus1, :ue},
      field: {:cpb_size_value_minus1, :ue},
      field: {:cbr_flag, :u1},
    },
    field: {:initial_cpb_removal_delay_length_minus1, :u5},
    field: {:cpb_removal_delay_length_minus1, :u5},
    field: {:dpb_output_delay_length_minus1, :u5},
    field: {:time_offset_length, :u5},
  ]
  def scaling_list(payload, state, _prefix, sizeOfScalingList) do
    lastScale = 8
    nextScale = 8
    {state, payload, _lastScale} = 1..sizeOfScalingList |> Enum.reduce({state, payload, lastScale}, fn _j, {state, payload} ->
      {payload, nextScale} = if nextScale !=0 do
        {delta_scale, payload} = Membrane.H264.Common.to_integer(payload, negatives: true)
        nextScale = rem(lastScale+delta_scale+256, 256)
        {payload, nextScale}
      else
        {payload, nextScale}
      end
      lastScale = if nextScale==0, do: lastScale, else: nextScale
      {state, payload, lastScale}
    end)
    {state, payload}
  end

end
