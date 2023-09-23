defmodule Membrane.H264.NALuParser.Schemes.NALuHeader do
  @moduledoc false
  @behaviour Membrane.H2645.NALuParser.Scheme

  @impl true
  def defaults(), do: []

  @impl true
  def scheme(),
    do: [
      field: {:forbidden_zero_bit, :u1},
      field: {:nal_ref_idc, :u2},
      field: {:nal_unit_type, :u5}
    ]
end
