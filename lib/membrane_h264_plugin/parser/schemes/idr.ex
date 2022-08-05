defmodule Membrane.H264.Parser.Schemes.Slice do
  def scheme, do: [
    field: {:forbidden_zero_bit, :u1},
    field: {:nal_ref_idc, :u2},
    field: {:nal_unit_type, :u5}
  ]++slice_header()

  def slice_header, do: [
    field: {:first_mb_in_slice, :ue},
    field: {:slice_type, :ue},
    field: {:pic_parameter_set_id, :ue},
    execute: fn state, payload, _prefix ->
      pps = Map.get(state.__pps__, state.pic_parameter_set_id)
      sps = Map.get(state.__sps__, pps.seq_parameter_set_id)
      state = Map.put(state, :separate_colour_plane_flag, Map.get(sps, :separate_colour_plane_flag, 0))
      state = Map.put(state, :log2_max_frame_num_minus4, Map.fetch!(sps, :log2_max_frame_num_minus4))
      state = Map.put(state, :frame_mbs_only_flag, Map.fetch!(sps, :frame_mbs_only_flag))
      state = Map.put(state, :pic_order_cnt_type, Map.fetch!(sps, :pic_order_cnt_type))
      state = Map.put(state, :log2_max_pic_order_cnt_lsb_minus4, Map.fetch!(sps, :log2_max_pic_order_cnt_lsb_minus4))

      state = state |> Map.delete(:__pps__) |> Map.delete(:__sps__)
      {state, payload}
    end,
    if: { {fn x-> x==1 end, [:separate_colour_plane_flag]},
      field: {:colour_plane_id, :u2}
    },
    field: {:frame_num, {:uv, &(&1+4), [:log2_max_frame_num_minus4]}},
    if: { {&(&1!=1), [:frame_mbs_only_flag]},
      field: {:field_pic_flag, :u1},
      if: { {&(&1==1), [:field_pic_flag]},
        field: {:bottom_field_flag, :u1}
      }
    },
    if: {{&(&1==5), [:nal_unit_type]},
      field: {:idr_pic_id, :ue}
    },
    if: { {&(&1==0), [:pic_order_cnt_type]},
      field: {:pic_order_cnt_lsb, {:uv, &(&1+4), [:log2_max_pic_order_cnt_lsb_minus4]}},
    }
  ]
end
