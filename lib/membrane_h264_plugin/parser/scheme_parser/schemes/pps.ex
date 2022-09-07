defmodule Membrane.H264.Parser.SchemeParser.Schemes.PPS do
  @moduledoc false
  @behaviour Membrane.H264.Parser.SchemeParser.Scheme

  @impl true
  def scheme(),
    do: [
      field: {:pic_parameter_set_id, :ue},
      field: {:seq_parameter_set_id, :ue},
      save_state_as_global_state: {&{:pps, &1}, [:pic_parameter_set_id]}
    ]
end
