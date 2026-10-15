defmodule Membrane.H264.NALuParser.Schemes.Common do
  @moduledoc false

  # Quoted schemes of the syntax structures shared between (or nested in) the NALu
  # schemes, spliced into them at compile time.

  @spec vui_parameters() :: Macro.t()
  def vui_parameters() do
    quote do
      [
        field: {:aspect_ratio_present_flag, :u1},
        if:
          {{&(&1 == 1), [:aspect_ratio_present_flag]},
           field: {:aspect_ratio_idc, :u8},
           if:
             {{&(&1 == 255), [:aspect_ratio_idc]},
              field: {:sar_width, :u16}, field: {:sar_height, :u16}}},
        field: {:overscan_info_present_flag, :u1},
        if:
          {{&(&1 == 1), [:overscan_info_present_flag]}, field: {:overscan_appropriate_flag, :u1}},
        field: {:video_signal_type_present_flag, :u1},
        if:
          {{&(&1 == 1), [:video_signal_type_present_flag]},
           field: {:video_format, :u3},
           field: {:video_full_range_flag, :u1},
           field: {:colour_description_present_flag, :u1},
           if:
             {{&(&1 == 1), [:colour_description_present_flag]},
              field: {:colour_primaries, :u8},
              field: {:transfer_characteristics, :u8},
              field: {:matrix_coefficients, :u8}}},
        field: {:chroma_loc_info_present_flag, :u1},
        if:
          {{&(&1 == 1), [:chroma_loc_info_present_flag]},
           field: {:chroma_sample_loc_type_top_field, :ue},
           field: {:chroma_sample_loc_type_bottom_field, :ue}},
        field: {:timing_info_present_flag, :u1},
        if:
          {{&(&1 == 1), [:timing_info_present_flag]},
           field: {:num_units_in_tick, :u32},
           field: {:time_scale, :u32},
           field: {:fixed_frame_rate_flag, :u1}},
        field: {:nal_hrd_parameters_present_flag, :u1},
        if: {{&(&1 == 1), [:nal_hrd_parameters_present_flag]}, unquote(hrd_parameters())},
        field: {:vcl_hrd_parameters_present_flag, :u1},
        if: {{&(&1 == 1), [:vcl_hrd_parameters_present_flag]}, unquote(hrd_parameters())},
        if:
          {{&(&1 == 1 or &2 == 1),
            [:nal_hrd_parameters_present_flag, :vcl_hrd_parameters_present_flag]},
           field: {:low_delay_hrd_flag, :u1}},
        field: {:pic_struct_present_flag, :u1},
        field: {:bitstream_restriction_flag, :u1},
        if:
          {{&(&1 == 1), [:bitstream_restriction_flag]},
           field: {:motion_vectors_over_pic_boundaries_flag, :u1},
           field: {:max_bytes_per_pic_denom, :ue},
           field: {:max_bits_per_mb_denom, :ue},
           field: {:log2_max_mv_length_horizontal, :ue},
           field: {:log2_max_mv_length_vertical, :ue},
           field: {:max_num_reorder_frames, :ue},
           field: {:max_dec_frame_buffering, :ue}}
      ]
    end
  end

  @spec hrd_parameters() :: Macro.t()
  def hrd_parameters() do
    quote do
      [
        field: {:cpb_cnt_minus1, :ue},
        field: {:bit_rate_scale, :u4},
        field: {:cpb_size_scale, :u4},
        for:
          {[iterator: :schedSeiIdx, from: 1, to: {&(&1 + 1), [:cpb_cnt_minus1]}],
           field: {:bit_rate_value_minus1, :ue},
           field: {:cpb_size_value_minus1, :ue},
           field: {:cbr_flag, :u1}},
        field: {:initial_cpb_removal_delay_length_minus1, :u5},
        field: {:cpb_removal_delay_length_minus1, :u5},
        field: {:dpb_output_delay_length_minus1, :u5},
        field: {:time_offset_length, :u5}
      ]
    end
  end
end
