defmodule Membrane.H264.Parser.Schemes.PPS do
  def scheme, do: [
    field: {:pic_parameter_set_id, :ue},
    field: {:seq_parameter_set_id, :ue},
    save_state_as_global_state: {fn field -> {:pps, field} end,  [:pic_parameter_set_id]}
  ]
end
