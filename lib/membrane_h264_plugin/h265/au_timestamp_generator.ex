defmodule Membrane.H265.AUTimestampGenerator do
  @moduledoc false

  use Membrane.H26x.AUTimestampGenerator

  require Membrane.H265.NALuTypes, as: NALuTypes

  @impl true
  def get_first_vcl_nalu(au) do
    Enum.find(au, &NALuTypes.is_vcl_nalu_type(&1.type))
  end

  @impl true
  # Calculate picture order count according to section 8.3.1 of the ITU-T H265 specification
  def calculate_poc(vcl_nalu, state) do
    max_pic_order_cnt_lsb = 2 ** (vcl_nalu.parsed_fields.log2_max_pic_order_cnt_lsb_minus4 + 4)

    # We exclude CRA pictures from IRAP pictures since we have no way
    # to assert the value of the flag NoRaslOutputFlag.
    # If the CRA is the first access unit in the bytestream, the flag would be
    # equal to 1 which reset the POC counter, and that condition is
    # satisfied here since the initial value for prev_pic_order_cnt_msb and
    # prev_pic_order_cnt_lsb are 0
    {prev_pic_order_cnt_msb, prev_pic_order_cnt_lsb} =
      if vcl_nalu.parsed_fields.nal_unit_type in 16..20 do
        {0, 0}
      else
        {state.prev_pic_order_cnt_msb,
         state.prev_pic_first_vcl_nalu.parsed_fields.pic_order_cnt_lsb}
      end

    pic_order_cnt_lsb = vcl_nalu.parsed_fields.pic_order_cnt_lsb

    pic_order_cnt_msb =
      cond do
        pic_order_cnt_lsb < prev_pic_order_cnt_lsb and
            prev_pic_order_cnt_lsb - pic_order_cnt_lsb >= div(max_pic_order_cnt_lsb, 2) ->
          prev_pic_order_cnt_msb + max_pic_order_cnt_lsb

        pic_order_cnt_lsb > prev_pic_order_cnt_lsb and
            pic_order_cnt_lsb - prev_pic_order_cnt_lsb > div(max_pic_order_cnt_lsb, 2) ->
          prev_pic_order_cnt_msb - max_pic_order_cnt_lsb

        true ->
          prev_pic_order_cnt_msb
      end

    {prev_pic_first_vcl_nalu, prev_pic_order_cnt_msb} =
      if vcl_nalu.type in [:radl_r, :radl_n, :rasl_r, :rasl_n] or
           vcl_nalu.parsed_fields.nal_unit_type in 0..15//2 do
        {state.prev_pic_first_vcl_nalu, prev_pic_order_cnt_msb}
      else
        {vcl_nalu, pic_order_cnt_msb}
      end

    {pic_order_cnt_msb + pic_order_cnt_lsb,
     %{
       state
       | prev_pic_order_cnt_msb: prev_pic_order_cnt_msb,
         prev_pic_first_vcl_nalu: prev_pic_first_vcl_nalu
     }}
  end
end
