defmodule Membrane.H264.BinaryParser do
  alias Membrane.H264.Parser.{NALu, NALuPayload, Schemes}

  @non_vcl_nalus [:sps, :pps, :aud, :sei]
  @vcl_nalus [:idr, :non_idr, :part_a, :part_b, :part_c]

  def parse_binary(binary) do
    nalus = NALu.parse(binary)

    {nalus, _metadata} =
      Enum.map_reduce(nalus, %{pps: %{}, sps: %{}}, fn nalu, metadata ->
        {nalu_start_in_bytes, nalu_size_in_bytes} = nalu.unprefixed_poslen

        nalu_start = nalu_start_in_bytes * 8

        <<_beggining::size(nalu_start), nalu_payload::binary-size(nalu_size_in_bytes),
          _rest::bitstring>> = binary

        case nalu.type do
          :sps ->
            {parsed_state, _rest_of_payload} =
              NALuPayload.parse_scheme(nalu_payload, Schemes.SPS.scheme())

            {Map.put(nalu, :parsed, parsed_state),
             Map.put(
               metadata,
               :sps,
               Map.put(metadata.sps, parsed_state.seq_parameter_set_id, parsed_state)
             )}

          :pps ->
            {parsed_state, _rest_of_payload} =
              NALuPayload.parse_scheme(nalu_payload, Schemes.PPS.scheme())

            {Map.put(nalu, :parsed, parsed_state),
             Map.put(
               metadata,
               :pps,
               Map.put(metadata.pps, parsed_state.pic_parameter_set_id, parsed_state)
             )}

          :idr ->
            {parsed_state, _rest_of_payload} =
              NALuPayload.parse_scheme(nalu_payload, Schemes.Slice.scheme(), %{
                __pps__: metadata.pps,
                __sps__: metadata.sps
              })

            {Map.put(nalu, :parsed, parsed_state), metadata}

          :non_idr ->
            {parsed_state, _rest_of_payload} =
              NALuPayload.parse_scheme(nalu_payload, Schemes.Slice.scheme(), %{
                __pps__: metadata.pps,
                __sps__: metadata.sps
              })

            {Map.put(nalu, :parsed, parsed_state), metadata}

          _ ->
            {nalu, metadata}
        end
      end)

    nalus
  end

  def split_binary_into_access_units(binary) do
    parsed_nalus = parse_binary(binary)
    split_nalus_into_access_units(parsed_nalus)
  end

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
        raise "Improper transition"
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
        raise "Improper transition"
    end
  end

  defp split_nalus_into_access_units([] = nalus, buffer, state, vcl_state, access_units) do
    {nalus, buffer, state, vcl_state, access_units}
  end

  defp is_new_primary_coded_vcl_nalu(nalu, last_nalu) do
    if nalu.type in @vcl_nalus do
      cond do
        last_nalu == nil ->
          true

        nalu.parsed.frame_num != last_nalu.parsed.frame_num ->
          true

        nalu.parsed.pic_parameter_set_id != last_nalu.parsed.pic_parameter_set_id ->
          true

        Map.has_key?(nalu.parsed, :field_pic_flag) and
          Map.has_key?(last_nalu.parsed, :field_pic_flag) and
            nalu.parsed.field_pic_flag != last_nalu.parsed.field_pic_flag ->
          true

        Map.has_key?(nalu.parsed, :field_pic_flag) and
          Map.has_key?(last_nalu.parsed, :field_pic_flag) and nalu.parsed.field_pic_flag == 1 and
          last_nalu.parsed.field_pic_flag == 1 and
            nalu.parsed.bottom_field_flag != last_nalu.parsed.bottom_field_flag ->
          true

        nalu.parsed.nal_ref_idc != last_nalu.parsed.nal_ref_idc and
            Enum.any?([nalu.parsed.nal_ref_idc, last_nalu.parsed.nal_ref_idc], &(&1 == 0)) ->
          true

        nalu.parsed.pic_order_cnt_type == 0 and last_nalu.parsed.pic_order_cnt_type == 0 and
            nalu.parsed.pic_order_cnt_lsb != last_nalu.parsed.pic_order_cnt_lsb ->
          true

        Map.has_key?(nalu.parsed, :delta_pic_order_cnt_bottom) and
          Map.has_key?(last_nalu.parsed, :delta_pic_order_cnt_bottom) and
            nalu.parsed.delta_pic_order_cnt_bottom != last_nalu.parsed.delta_pic_order_cnt_bottom ->
          true

        true ->
          false
      end
    else
      false
    end
  end
end
