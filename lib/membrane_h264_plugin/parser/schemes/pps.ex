defmodule Membrane.H264.Parser.Schemes.PPS do
  def scheme, do: [
    field: {:forbidden_zero_bit, :u1},
    field: {:nal_ref_idc, :u2},
    field: {:nalu_unit_type, :u5},
    field: {:pic_parameter_set_id, :ue},
    field: {:seq_parameter_set_id, :ue}
  ]
end
