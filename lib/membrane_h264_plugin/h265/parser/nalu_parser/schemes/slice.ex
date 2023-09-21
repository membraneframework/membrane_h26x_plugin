defmodule Membrane.H265.Parser.NALuParser.Schemes.Slice do
  @moduledoc false
  @behaviour Membrane.H26x.Common.Parser.NALuParser.Scheme

  @impl true
  def defaults(),
    do: [
      dependent_slice_segment_flag: 0,
      no_output_of_prior_pics_flag: 0,
      pic_output_flag: 1,
      pic_order_cnt_lsb: 0
    ]

  @impl true
  def scheme(),
    do: [
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

      sps_fields = Map.take(sps, [:segment_addr_length, :log2_max_pic_order_cnt_lsb_minus4])
      state = Map.update(state, :__local__, %{}, &Map.merge(&1, sps_fields))

      # PPS fields
      pps_fields =
        Map.take(pps, [
          :dependent_slice_segments_enabled_flag,
          :output_flag_present_flag,
          :num_extra_slice_header_bits
        ])

      state = Map.update(state, :__local__, %{}, &Map.merge(&1, pps_fields))

      {payload, state}
    else
      _error -> throw(state)
    end
  end
end
