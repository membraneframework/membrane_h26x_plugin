defmodule Membrane.H264.NALuParser.Schemes.NALuHeader do
  @moduledoc false
  use Membrane.H26x.ParsingEngine.NALuParser.Scheme

  defscheme do
    [
      field: {:forbidden_zero_bit, :u1},
      field: {:nal_ref_idc, :u2},
      field: {:nal_unit_type, :u5}
    ]
  end
end
