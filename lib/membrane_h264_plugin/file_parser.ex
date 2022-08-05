defmodule Membrane.H264.FileParser do
  alias Membrane.H264.Parser.{NALu, NALuPayload, Schemes}

  @non_vcl_nalus [:sps, :pps, :aud, :sei]

  def parse(binary) do
    nalus = NALu.parse(binary)

    Enum.map_reduce(nalus, %{pps: %{}, sps: %{}}, fn nalu, metadata ->
      {nalu_start_in_bytes, nalu_size_in_bytes} = nalu.unprefixed_poslen

      nalu_start = nalu_start_in_bytes*8
      <<_beggining::size(nalu_start), nalu_payload::binary-size(nalu_size_in_bytes), _rest::bitstring>> = binary
      case nalu.type do
        :sps -> {parsed_state, _rest_of_payload} = NALuPayload.parse_scheme(nalu_payload, Schemes.SPS.scheme)
          {Map.put(nalu, :parsed, parsed_state), Map.put(metadata, :sps, Map.put(metadata.sps, parsed_state.seq_parameter_set_id, parsed_state))}
        :pps -> {parsed_state, _rest_of_payload} = NALuPayload.parse_scheme(nalu_payload, Schemes.PPS.scheme)
          {Map.put(nalu, :parsed, parsed_state), Map.put(metadata, :pps, Map.put(metadata.pps, parsed_state.pic_parameter_set_id, parsed_state))}
        :idr -> {parsed_state, _rest_of_payload} = NALuPayload.parse_scheme(nalu_payload, Schemes.Slice.scheme, %{__pps__: metadata.pps, __sps__: metadata.sps})
          {Map.put(nalu, :parsed, parsed_state), metadata}
        :non_idr -> {parsed_state, _rest_of_payload} = NALuPayload.parse_scheme(nalu_payload, Schemes.Slice.scheme, %{__pps__: metadata.pps, __sps__: metadata.sps})
          {Map.put(nalu, :parsed, parsed_state), metadata}
        _ -> {nalu, metadata}
      end
    end)

  end

  def split_binary_into_aud(binary) do
    {parsed_nalus, _state} = parse(binary)
    split_nalus_into_aud(parsed_nalus)
  end

  def split_nalus_into_aud(nalus, buffer \\ [], state \\ :first, vcl_state \\ %{}, auds \\ [])

  def split_nalus_into_aud([first_nalu| rest_nalus], buffer, :first, vcl_state, auds)
  do
    cond do
      is_new_primary_coded_vcl_nalu(first_nalu, vcl_state) ->
        split_nalus_into_aud(rest_nalus, buffer++[first_nalu], :second, Map.put(vcl_state, :last_nalu, first_nalu), auds)
      first_nalu.type in @non_vcl_nalus  ->
        split_nalus_into_aud(rest_nalus, buffer++[first_nalu], :first, vcl_state, auds)
      true -> raise "Improper transition"
    end
  end

  def split_nalus_into_aud([first_nalu| rest_nalus]=nalus, buffer, :second, vcl_state, auds)
  do
    cond do
      first_nalu.type in @non_vcl_nalus  ->
        split_nalus_into_aud(nalus, [], :first, vcl_state, auds++[buffer])
      is_new_primary_coded_vcl_nalu(first_nalu, vcl_state) -> split_nalus_into_aud(rest_nalus, [first_nalu], :second, Map.put(vcl_state, :last_nalu, first_nalu), auds++[buffer])
      true ->
        split_nalus_into_aud(rest_nalus, buffer++[first_nalu], :second, vcl_state, auds)
    end
  end

  def split_nalus_into_aud([], _buffer, _state, _vcl_state, auds) do
    auds
  end


  def is_new_primary_coded_vcl_nalu(nalu, state \\ %{}) do
    if (nalu.type == :idr or nalu.type == :non_idr) do
      last_nalu = Map.get(state, :last_nalu)
      cond do
        last_nalu == nil -> true
        nalu.parsed.frame_num != last_nalu.parsed.frame_num -> true
        nalu.parsed.pic_parameter_set_id != last_nalu.parsed.pic_parameter_set_id -> true
        Map.has_key?(nalu.parsed, :field_pic_flag) and Map.has_key?(last_nalu.parsed, :field_pic_flag) and nalu.parsed.field_pic_flag != last_nalu.parsed.field_pic_flag -> true
        Map.has_key?(nalu.parsed, :field_pic_flag) and Map.has_key?(last_nalu.parsed, :field_pic_flag) and nalu.parsed.field_pic_flag == 1 and last_nalu.parsed.field_pic_flag == 1 and nalu.parsed.bottom_field_flag != last_nalu.parsed.bottom_field_flag -> true
        (nalu.parsed.nal_ref_idc != last_nalu.parsed.nal_ref_idc) and Enum.any?([nalu.parsed.nal_ref_idc, last_nalu.parsed.nal_ref_idc], &(&1==0)) -> true
        (nalu.parsed.pic_order_cnt_type == 0 and last_nalu.parsed.pic_order_cnt_type == 0 and nalu.parsed.pic_order_cnt_lsb != last_nalu.parsed.pic_order_cnt_lsb ) -> true
        Map.has_key?(nalu.parsed, :delta_pic_order_cnt_bottom) and Map.has_key?(last_nalu.parsed, :delta_pic_order_cnt_bottom) and nalu.parsed.delta_pic_order_cnt_bottom != last_nalu.parsed.delta_pic_order_cnt_bottom -> true
        true -> false
      end
      else
        false
      end
    end
end
