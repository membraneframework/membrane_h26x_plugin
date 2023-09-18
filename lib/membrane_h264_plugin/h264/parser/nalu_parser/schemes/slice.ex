defmodule Membrane.H264.Parser.NALuParser.Schemes.Slice do
  @moduledoc false
  @behaviour Membrane.H26x.Common.Parser.NALuParser.Scheme

  @impl true
  def defaults(), do: []

  # If we're ever unlucky and have to parse more fields from the slice header
  # this implementation may come in handy:
  # https://webrtc.googlesource.com/src/webrtc/+/f54860e9ef0b68e182a01edc994626d21961bc4b/common_video/h264/h264_bitstream_parser.cc
  @impl true
  def scheme(),
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
    with pic_parameter_set_id when pic_parameter_set_id != nil <-
           Map.get(state.__local__, :pic_parameter_set_id),
         pps when pps != nil <- Map.get(state.__global__, {:pps, pic_parameter_set_id}),
         seq_parameter_set_id when seq_parameter_set_id != nil <-
           Map.get(pps, :seq_parameter_set_id),
         sps <- Map.get(state.__global__, {:sps, seq_parameter_set_id}) do
      state =
        Bunch.Access.put_in(
          state,
          [:__local__, :separate_colour_plane_flag],
          Map.get(sps, :separate_colour_plane_flag, 0)
        )

      sps_fields =
        Map.take(sps, [
          :log2_max_frame_num_minus4,
          :frame_mbs_only_flag,
          :pic_order_cnt_type,
          :log2_max_pic_order_cnt_lsb_minus4
        ])

      state = Map.update(state, :__local__, %{}, &Map.merge(&1, sps_fields))

      {payload, state}
    else
      _error -> throw("Cannot load information from SPS")
    end
  end
end
