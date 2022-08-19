defmodule Membrane.H264.Parser.Schemes.Slice do
  @moduledoc false
  @behaviour Membrane.H264.Parser.Scheme

  @impl true
  def scheme(), do: slice_header()

  defp slice_header,
    do: [
      field: {:first_mb_in_slice, :ue},
      field: {:slice_type, :ue},
      field: {:pic_parameter_set_id, :ue},
      execute: &load_data_from_sps(&1, &2, &3),
      if: {{&(&1 == 1), [:separate_colour_plane_flag]}, field: {:colour_plane_id, :u2}},
      field: {:frame_num, {:uv, &(&1 + 4), [:log2_max_frame_num_minus4]}},
      if:
        {{&(&1 != 1), [:frame_mbs_only_flag]},
         field: {:field_pic_flag, :u1},
         if: {{&(&1 == 1), [:field_pic_flag]}, field: {:bottom_field_flag, :u1}}},
      if: {{&(&1 == 5), [:nal_unit_type]}, field: {:idr_pic_id, :ue}},
      if:
        {{&(&1 == 0), [:pic_order_cnt_type]},
         field: {:pic_order_cnt_lsb, {:uv, &(&1 + 4), [:log2_max_pic_order_cnt_lsb_minus4]}}}
    ]

  defp load_data_from_sps(payload, state, _iterators) do
    pps = Map.get(state.__global__, {:pps, state.__local__.pic_parameter_set_id})
    sps = Map.get(state.__global__, {:sps, pps.seq_parameter_set_id})

    state =
      Bunch.Access.put_in(
        state,
        [:__local__, :separate_colour_plane_flag],
        Map.get(sps, :separate_colour_plane_flag, 0)
      )

    state =
      Bunch.Access.put_in(
        state,
        [:__local__, :log2_max_frame_num_minus4],
        Map.get(sps, :log2_max_frame_num_minus4)
      )

    state =
      Bunch.Access.put_in(
        state,
        [:__local__, :frame_mbs_only_flag],
        Map.get(sps, :frame_mbs_only_flag)
      )

    state =
      Bunch.Access.put_in(
        state,
        [:__local__, :pic_order_cnt_type],
        Map.get(sps, :pic_order_cnt_type)
      )

    state =
      Bunch.Access.put_in(
        state,
        [:__local__, :log2_max_pic_order_cnt_lsb_minus4],
        Map.get(sps, :log2_max_pic_order_cnt_lsb_minus4)
      )

    {payload, state}
  end
end
