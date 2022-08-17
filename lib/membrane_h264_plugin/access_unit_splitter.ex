defmodule Membrane.H264.AccessUnitSplitter do
  @moduledoc """
  Module providing functionalities to divide the binary h264 stream into access units.
  """
  alias Membrane.H264.Parser.NALu

  @non_vcl_nalus [:sps, :pps, :aud, :sei]
  @vcl_nalus [:idr, :non_idr, :part_a, :part_b, :part_c]

  @type access_unit_t() :: list(NALu.nalu_t())

  @spec split_binary_into_access_units(binary()) :: list(access_unit_t())
  @doc """
  Parses the provided binary with the NALu parser and splits the received list of NALus into multiple sublists,
  with each of these sublists containing NALus from one access unit.
  """
  def split_binary_into_access_units(binary) do
    {parsed_nalus, _state} = NALu.parse(binary)

    {_nalus, _buffer, _state, _previous_primary_coded_picture_nalu, access_units} =
      split_nalus_into_access_units(parsed_nalus)

    access_units
  end

  # split_nalus_into_access_units/5 defines a finite state machine with two states: :first and :second.
  # The state :first describes the state before reaching the primary coded picture NALu of a given access unit.
  # The state :second describes the state after processing the primary coded picture NALu of a given access unit.

  defp split_nalus_into_access_units(
         nalus,
         buffer \\ [],
         state \\ :first,
         previous_primary_coded_picture_nalu \\ nil,
         access_units \\ []
       )

  defp split_nalus_into_access_units(
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

  defp split_nalus_into_access_units(
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

  defp split_nalus_into_access_units(
         [] = nalus,
         buffer,
         state,
         previous_primary_coded_picture_nalu,
         access_units
       ) do
    {nalus, buffer, state, previous_primary_coded_picture_nalu, access_units}
  end

  defp is_new_primary_coded_vcl_nalu(nalu, last_nalu) do
    # See: 7.4.1.2.4 Detection of the first VCL NAL unit of a primary coded picture of the "ITU-T Rec. H.264 (01/2012)"

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
            (nalu.parsed_fields.pic_order_cnt_lsb != last_nalu.parsed_fields.pic_order_cnt_lsb or
               Map.get(nalu.parsed_fields, :delta_pic_order_cnt_bottom) !=
                 Map.get(last_nalu.parsed_fields, :delta_pic_order_cnt_bottom)) ->
          true

        nalu.parsed_fields.pic_order_cnt_type == 1 and
          last_nalu.parsed_fields.pic_order_cnt_type == 1 and
            (Bunch.Access.get_in(nalu.parsed_fields, [:delta_pic_order_cnt, 0]) !=
               Bunch.Access.get_in(last_nalu.parsed_fields, [:delta_pic_order_cnt, 0]) or
               Bunch.Access.get_in(nalu.parsed_fields, [:delta_pic_order_cnt, 1]) !=
                 Bunch.Access.get_in(last_nalu.parsed_fields, [:delta_pic_order_cnt, 1])) ->
          true

        # The following condition to be checked is also specified in the documentation: "IdrPicFlag is equal to 1 for both and idr_pic_id differs in value".
        # At the same time, it seems that it describes the situation, that we are having two different IDR frames - and that should imply, that their frame_num
        # should differ, which is already checked in the second condition

        true ->
          false
      end
    else
      false
    end
  end
end
