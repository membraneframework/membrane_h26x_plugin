defmodule Membrane.H265.NALuParser.Schemes.PPS do
  @moduledoc false
  @behaviour Membrane.H2645.NALuParser.Scheme

  @impl true
  def defaults(), do: []

  @impl true
  def scheme(),
    do: [
      field: {:pic_parameter_set_id, :ue},
      field: {:seq_parameter_set_id, :ue},
      field: {:dependent_slice_segments_enabled_flag, :u1},
      field: {:output_flag_present_flag, :u1},
      field: {:num_extra_slice_header_bits, :u3},
      save_state_as_global_state: {&{:pps, &1}, [:pic_parameter_set_id]}
    ]
end
