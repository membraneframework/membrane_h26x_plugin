defmodule Membrane.H264.AccessUnitSplitter do
  alias Membrane.H264.Parser.NALu

  @non_vcl_nalus [:sps, :pps, :aud, :sei]
  @vcl_nalus [:idr, :non_idr, :part_a, :part_b, :part_c]

  def split_binary_into_access_units(binary) do
    {parsed_nalus} = NALu.parse(binary)
    split_nalus_into_access_units(parsed_nalus)
  end

  def split_nalus_into_access_units(
        nalus,
        buffer \\ [],
        state \\ :first,
        previous_primary_coded_picture_nalu \\ nil,
        access_units \\ []
      )

  def split_nalus_into_access_units(
        [first_nalu | rest_nalus],
        buffer,
        :first,
        previous_primary_coded_picture_nalu,
        access_units
      ) do
    cond do
      is_new_primary_coded_vcl_nalu(first_nalu, previous_primary_coded_picture_nalu) ->
        split_nalus_into_access_units(
          rest_nalus,
          buffer ++ [first_nalu],
          :second,
          first_nalu,
          access_units
        )

      first_nalu.type in @non_vcl_nalus ->
        split_nalus_into_access_units(
          rest_nalus,
          buffer ++ [first_nalu],
          :first,
          previous_primary_coded_picture_nalu,
          access_units
        )

      true ->
        raise "AccessUnitSplitter: Improper transition"
    end
  end

  def split_nalus_into_access_units(
        [first_nalu | rest_nalus],
        buffer,
        :second,
        previous_primary_coded_picture_nalu,
        access_units
      ) do
    cond do
      first_nalu.type in @non_vcl_nalus ->
        split_nalus_into_access_units(
          rest_nalus,
          [first_nalu],
          :first,
          previous_primary_coded_picture_nalu,
          access_units ++ [buffer]
        )

      is_new_primary_coded_vcl_nalu(first_nalu, previous_primary_coded_picture_nalu) ->
        split_nalus_into_access_units(
          rest_nalus,
          [first_nalu],
          :second,
          first_nalu,
          access_units ++ [buffer]
        )

      first_nalu.type in @vcl_nalus ->
        split_nalus_into_access_units(
          rest_nalus,
          buffer ++ [first_nalu],
          :second,
          previous_primary_coded_picture_nalu,
          access_units
        )

      true ->
        raise "AccessUnitSplitter: Improper transition"
    end
  end

  def split_nalus_into_access_units(
        [] = nalus,
        buffer,
        state,
        vcl_state,
        access_units
      ) do
    {nalus, buffer, state, vcl_state, access_units}
  end

  defp is_new_primary_coded_vcl_nalu(nalu, last_nalu) do
    if nalu.type in @vcl_nalus do
      cond do
        last_nalu == nil ->
          true

        nalu.parsed_fields.frame_num != last_nalu.parsed_fields.frame_num ->
          true

        nalu.parsed_fields.pic_parameter_set_id != last_nalu.parsed_fields.pic_parameter_set_id ->
          true

        Map.has_key?(nalu.parsed_fields, :field_pic_flag) and
          Map.has_key?(last_nalu.parsed_fields, :field_pic_flag) and
            nalu.parsed_fields.field_pic_flag != last_nalu.parsed_fields.field_pic_flag ->
          true

        Map.has_key?(nalu.parsed_fields, :field_pic_flag) and
          Map.has_key?(last_nalu.parsed_fields, :field_pic_flag) and
          nalu.parsed_fields.field_pic_flag == 1 and
          last_nalu.parsed_fields.field_pic_flag == 1 and
            nalu.parsed_fields.bottom_field_flag != last_nalu.parsed_fields.bottom_field_flag ->
          true

        nalu.parsed_fields.nal_ref_idc != last_nalu.parsed_fields.nal_ref_idc and
            Enum.any?(
              [nalu.parsed_fields.nal_ref_idc, last_nalu.parsed_fields.nal_ref_idc],
              &(&1 == 0)
            ) ->
          true

        nalu.parsed_fields.pic_order_cnt_type == 0 and
          last_nalu.parsed_fields.pic_order_cnt_type == 0 and
            nalu.parsed_fields.pic_order_cnt_lsb != last_nalu.parsed_fields.pic_order_cnt_lsb ->
          true

        Map.has_key?(nalu.parsed_fields, :delta_pic_order_cnt_bottom) and
          Map.has_key?(last_nalu.parsed_fields, :delta_pic_order_cnt_bottom) and
            nalu.parsed_fields.delta_pic_order_cnt_bottom !=
              last_nalu.parsed_fields.delta_pic_order_cnt_bottom ->
          true

        true ->
          false
      end
    else
      false
    end
  end
end
