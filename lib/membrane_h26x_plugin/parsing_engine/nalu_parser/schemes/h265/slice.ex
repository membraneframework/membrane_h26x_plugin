defmodule Membrane.H265.NALuParser.Schemes.Slice do
  @moduledoc false
  use Membrane.H26x.ParsingEngine.NALuParser.Scheme

  # The slice segment header fields read below fit in a few dozen bytes even with
  # the emulation prevention bytes in place, so the rest of the slice is never unescaped.
  defscheme defaults: [
              dependent_slice_segment_flag: 0,
              no_output_of_prior_pics_flag: 0,
              pic_output_flag: 1,
              pic_order_cnt_lsb: 0
            ],
            max_bytes: 64 do
    [
      field: {:first_slice_segment_in_pic_flag, :u1},
      if: {
        {&(&1 >= 16 and &1 <= 23), [:nal_unit_type]},
        field: {:no_output_of_prior_pics_flag, :u1}
      },
      field: {:pic_parameter_set_id, :ue},
      execute: &load_data_from_sps/3,
      if: {
        {&(&1 == 0), [:first_slice_segment_in_pic_flag]},
        if: {
          {&(&1 == 1), [:dependent_slice_segments_enabled_flag]},
          field: {:dependent_slice_segment_flag, :u1}
        },
        field: {:slice_segment_address, {:uv, & &1, [:segment_addr_length]}}
      },
      if: {
        {&(&1 == 0), [:dependent_slice_segment_flag]},
        for: {
          [iterator: :j, from: 0, to: {&(&1 - 1), [:num_extra_slice_header_bits]}],
          field: {:slice_reserved_flag, :u1}
        },
        field: {:slice_type, :ue},
        if: {
          {&(&1 == 1), [:output_flag_present_flag]},
          field: {:pic_output_flag, :u1}
        },
        if: {
          {&(&1 == 1), [:separate_colour_plane_flag]},
          field: {:colour_plane_id, :u2}
        },
        if: {
          {&(&1 != 19 and &1 != 20), [:nal_unit_type]},
          field: {:pic_order_cnt_lsb, {:uv, &(&1 + 4), [:log2_max_pic_order_cnt_lsb_minus4]}}
        }
      }
    ]
  end

  @sps_fields [
    :segment_addr_length,
    :log2_max_pic_order_cnt_lsb_minus4,
    :sps_max_num_reorder_pics
  ]

  @pps_fields [
    :dependent_slice_segments_enabled_flag,
    :output_flag_present_flag,
    :num_extra_slice_header_bits
  ]

  defp load_data_from_sps(payload, state, _iterators) do
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
