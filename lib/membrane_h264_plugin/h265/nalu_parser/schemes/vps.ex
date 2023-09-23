defmodule Membrane.H265.NALuParser.Schemes.VPS do
  @moduledoc false

  @behaviour Membrane.H2645.NALuParser.Scheme

  alias Membrane.H265.NALuParser.Schemes.Common

  @impl true
  def defaults(), do: []

  @impl true
  def scheme(),
    do:
      [
        field: {:video_parameter_set_id, :u4},
        field: {:base_layer_internal_flag, :u1},
        field: {:base_layer_available_flag, :u1},
        field: {:max_layers_minus1, :u6},
        field: {:max_sub_layers_minus1, :u3},
        field: {:temporal_id_nesting_flag, :u1},
        field: {:reserved_0xffff_16bits, :u16}
      ] ++
        Common.profile_tier_level() ++
        [
          field: {:sub_layer_ordering_info_present_flag, :u1},
          for: {
            [
              iterator: :i,
              from:
                {&if(&1 == 1, do: 0, else: &2),
                 [:sub_layer_ordering_info_present_flag, :max_sub_layers_minus1]},
              to: {& &1, [:max_sub_layers_minus1]}
            ],
            field: {:max_dec_pic_buffering_minus1, :ue},
            field: {:max_num_reorder_pics, :ue},
            field: {:max_latency_increase_plus1, :ue}
          },
          field: {:max_layer_id, :u6},
          field: {:num_layer_sets_minus1, :ue},
          for: {
            [iterator: :i, from: 1, to: {& &1, [:num_layer_sets_minus1]}],
            for: {
              [iterator: :j, from: 0, to: {& &1, [:max_layer_id]}],
              field: {:layer_id_included_flag, :u1}
            }
          },
          field: {:timing_info_present_flag, :u1},
          if: {
            {&(&1 == 1), [:timing_info_present_flag]},
            field: {:num_units_in_tick, :u32},
            field: {:time_scale, :u32},
            field: {:poc_proportional_to_timing_flag, :u1},
            if: {
              {&(&1 == 1), [:poc_proportional_to_timing_flag]},
              field: {:num_ticks_poc_diff_one_minus1, :ue}
            }
          },
          save_state_as_global_state: {&{:vps, &1}, [:video_parameter_set_id]}
        ]
end
