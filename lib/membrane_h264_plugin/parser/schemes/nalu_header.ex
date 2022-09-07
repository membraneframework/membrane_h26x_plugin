defmodule Membrane.H264.Parser.Schemes.NALuHeader do
  @moduledoc false
  @behaviour Membrane.H264.Parser.Scheme
  alias Membrane.H264.Parser.NALuPayload
  alias Membrane.H264.Parser.Schemes

  @impl true
  def scheme(),
    do: [
      field: {:forbidden_zero_bit, :u1},
      field: {:nal_ref_idc, :u2},
      field: {:nal_unit_type, :u5}
    ]
end
