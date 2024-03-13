defmodule Membrane.H264.NALuParser.Schemes.PPS do
  @moduledoc false
  @behaviour Membrane.H26x.NALuParser.Scheme

  @impl true
  def defaults(), do: []

  @impl true
  def scheme(),
    do: [
      field: {:pic_parameter_set_id, :ue},
      field: {:seq_parameter_set_id, :ue},
      field: {:entropy_coding_mode_flag, :u1},
      field: {:bottom_field_pic_order_in_frame_present_flag, :u1},
      save_state_as_global_state: {&{:pps, &1}, [:pic_parameter_set_id]}
    ]
end
