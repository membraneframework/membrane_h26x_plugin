defmodule Membrane.H265.NALuParser.Schemes.NALuHeader do
  @moduledoc false
  use Membrane.H26x.ParsingEngine.NALuParser.Scheme

  defscheme do
    [
      field: {:forbidden_zero_bit, :u1},
      field: {:nal_unit_type, :u6},
      field: {:nuh_layer_id, :u6},
      field: {:nuh_temporal_id_plus1, :u3}
    ]
  end
end
