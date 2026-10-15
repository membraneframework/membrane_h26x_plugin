defmodule Membrane.H264.NALuParser.Schemes.Slice do
  @moduledoc false
  use Membrane.H26x.ParsingEngine.NALuParser.Scheme

  # The slice header fields read above fit in a few dozen bytes even with the
  # emulation prevention bytes in place, so the rest of the slice is never unescaped.
  #
  # If we're ever unlucky and have to parse more fields from the slice header
  # this implementation may come in handy:
  # https://webrtc.googlesource.com/src/webrtc/+/f54860e9ef0b68e182a01edc994626d21961bc4b/common_video/h264/h264_bitstream_parser.cc
  defscheme defaults: [field_pic_flag: 0, delta_pic_order_cnt_bottom: 0], max_bytes: 64 do
    [
      field: {:first_mb_in_slice, :ue},
      field: {:slice_type, :ue},
      field: {:pic_parameter_set_id, :ue},
      execute: &load_data_from_sps_and_pps(&1, &2, &3),
      if: {{&(&1 == 1), [:separate_colour_plane_flag]}, field: {:colour_plane_id, :u2}},
      field: {:frame_num, {:uv, &(&1 + 4), [:log2_max_frame_num_minus4]}},
      if:
        {{&(&1 != 1), [:frame_mbs_only_flag]},
         field: {:field_pic_flag, :u1},
         if: {{&(&1 == 1), [:field_pic_flag]}, field: {:bottom_field_flag, :u1}}},
      if: {{&(&1 == 5), [:nal_unit_type]}, field: {:idr_pic_id, :ue}},
      if:
        {{&(&1 == 0), [:pic_order_cnt_type]},
         field: {:pic_order_cnt_lsb, {:uv, &(&1 + 4), [:log2_max_pic_order_cnt_lsb_minus4]}},
         if:
           {{fn delta_pic_order_cnt_bottom, field_pic_flag ->
               delta_pic_order_cnt_bottom == 1 and field_pic_flag == 0
             end, [:bottom_field_pic_order_in_frame_present_flag, :field_pic_flag]},
            field: {:delta_pic_order_cnt_bottom, :se}}}
    ]
  end

  @sps_fields [
    :profile,
    :log2_max_frame_num_minus4,
    :frame_mbs_only_flag,
    :pic_order_cnt_type,
    :log2_max_pic_order_cnt_lsb_minus4,
    :vui_parameters_present_flag,
    :bitstream_restriction_flag,
    :max_num_reorder_frames
  ]

  @pps_fields [:bottom_field_pic_order_in_frame_present_flag]

  defp load_data_from_sps_and_pps(payload, state, _iterators) do
    with pic_parameter_set_id when pic_parameter_set_id != nil <-
           Map.get(state.__local__, :pic_parameter_set_id),
         pps when pps != nil <- Map.get(state.__global__, {:pps, pic_parameter_set_id}),
         seq_parameter_set_id when seq_parameter_set_id != nil <-
           Map.get(pps, :seq_parameter_set_id),
         sps when sps != nil <- Map.get(state.__global__, {:sps, seq_parameter_set_id}) do
      local =
        state.__local__
        |> Map.put(:separate_colour_plane_flag, Map.get(sps, :separate_colour_plane_flag, 0))
        |> Map.merge(Map.take(sps, @sps_fields))
        |> Map.merge(Map.take(pps, @pps_fields))

      {:ok, payload, %{state | __local__: local}}
    else
      _error -> {:error, state}
    end
  end
end
