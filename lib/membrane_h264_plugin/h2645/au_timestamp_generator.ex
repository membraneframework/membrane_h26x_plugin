defmodule Membrane.H2645.AUTimestampGenerator do
  @moduledoc false

  require Membrane.H264.NALuTypes, as: NALuTypes

  alias Membrane.H2645.NALu

  @type encoding :: :h264 | :h265
  @type framerate :: {frames :: pos_integer(), seconds :: pos_integer()}

  @type t :: %{
          encoding: :h264 | :h265,
          framerate: framerate,
          max_frame_reorder: 0..15,
          au_counter: non_neg_integer(),
          key_frame_au_idx: non_neg_integer(),
          prev_pic_first_vcl_nalu: NALu.t() | nil,
          prev_pic_order_cnt_msb: integer()
        }

  @spec new(
          encoding(),
          config :: %{:framerate => framerate, optional(:add_dts_offset) => boolean()}
        ) :: t
  def new(encoding, config) do
    # To make sure that PTS >= DTS at all times, we take maximal possible
    # frame reorder (which is 15 according to the spec) and subtract
    # `max_frame_reorder * frame_duration` from each frame's DTS.
    # This behaviour can be disabled by setting `add_dts_offset: false`.
    max_frame_reorder = if Map.get(config, :add_dts_offset, true), do: 15, else: 0

    %{
      encoding: encoding,
      framerate: config.framerate,
      max_frame_reorder: max_frame_reorder,
      au_counter: 0,
      key_frame_au_idx: 0,
      prev_pic_first_vcl_nalu: nil,
      prev_pic_order_cnt_msb: 0
    }
  end

  @spec generate_ts_with_constant_framerate([NALu.t()], t) ::
          {{pts :: non_neg_integer(), dts :: non_neg_integer()}, t}
  def generate_ts_with_constant_framerate(au, state) do
    %{
      au_counter: au_counter,
      key_frame_au_idx: key_frame_au_idx,
      max_frame_reorder: max_frame_reorder,
      framerate: {frames, seconds}
    } = state

    first_vcl_nalu = get_first_vcl_nalu(state.encoding, au)
    {poc, state} = calculate_poc(state.encoding, first_vcl_nalu, state)
    key_frame_au_idx = if poc == 0, do: au_counter, else: key_frame_au_idx
    pts = div((key_frame_au_idx + poc) * seconds * Membrane.Time.second(), frames)
    dts = div((au_counter - max_frame_reorder) * seconds * Membrane.Time.second(), frames)

    state = %{
      state
      | au_counter: au_counter + 1,
        key_frame_au_idx: key_frame_au_idx
    }

    {{pts, dts}, state}
  end

  defp get_first_vcl_nalu(:h264, au) do
    Enum.find(au, &NALuTypes.is_vcl_nalu_type(&1.type))
  end

  defp get_first_vcl_nalu(:h265, au) do
    Enum.find(au, &(&1.type in Membrane.H265.NALuTypes.vcl_nalu_types()))
  end

  # Calculate picture order count according to section 8.2.1 of the ITU-T H264 specification
  defp calculate_poc(:h264, %{parsed_fields: %{pic_order_cnt_type: 0}} = vcl_nalu, state) do
    max_pic_order_cnt_lsb = 2 ** (vcl_nalu.parsed_fields.log2_max_pic_order_cnt_lsb_minus4 + 4)

    {prev_pic_order_cnt_msb, prev_pic_order_cnt_lsb} =
      if vcl_nalu.type == :idr do
        {0, 0}
      else
        # TODO: As described in the spec, we should check for presence of the
        # memory_management_control_operation syntax element equal to 5
        # in the previous reference picture and calculate prev_pic_order_cnt_*sb
        # values accordingly if it's there. Since getting to that information
        # is quite a pain in the ass, we don't do that and assume it's not
        # there and it seems to work ¯\_(ツ)_/¯ However, it may happen not to work
        # for some streams and we may generate invalid timestamps because of that.
        # If that happens, may have to implement the aforementioned lacking part.

        previous_vcl_nalu = state.prev_pic_first_vcl_nalu || vcl_nalu
        {state.prev_pic_order_cnt_msb, previous_vcl_nalu.parsed_fields.pic_order_cnt_lsb}
      end

    pic_order_cnt_lsb = vcl_nalu.parsed_fields.pic_order_cnt_lsb

    pic_order_cnt_msb =
      cond do
        pic_order_cnt_lsb < prev_pic_order_cnt_lsb and
            prev_pic_order_cnt_lsb - pic_order_cnt_lsb >= max_pic_order_cnt_lsb / 2 ->
          prev_pic_order_cnt_msb + max_pic_order_cnt_lsb

        pic_order_cnt_lsb > prev_pic_order_cnt_lsb and
            pic_order_cnt_lsb - prev_pic_order_cnt_lsb > max_pic_order_cnt_lsb / 2 ->
          prev_pic_order_cnt_msb - max_pic_order_cnt_lsb

        true ->
          prev_pic_order_cnt_msb
      end

    pic_order_cnt =
      if get_slice_type(vcl_nalu) == :frame do
        top_field_order_cnt = pic_order_cnt_msb + pic_order_cnt_lsb

        bottom_field_order_cnt =
          top_field_order_cnt + vcl_nalu.parsed_fields.delta_pic_order_cnt_bottom

        min(top_field_order_cnt, bottom_field_order_cnt)
      else
        pic_order_cnt_msb + pic_order_cnt_lsb
      end

    {div(pic_order_cnt, 2),
     %{state | prev_pic_order_cnt_msb: pic_order_cnt_msb, prev_pic_first_vcl_nalu: vcl_nalu}}
  end

  defp calculate_poc(:h264, %{parsed_fields: %{pic_order_cnt_type: 1}}, _state) do
    raise "Timestamp generation error: unsupported stream. Unsupported field value pic_order_cnt_type=1"
  end

  defp calculate_poc(
         :h264,
         %{parsed_fields: %{pic_order_cnt_type: 2, frame_num: frame_num}} = vcl_nalu,
         state
       ) do
    {frame_num, %{state | prev_pic_first_vcl_nalu: vcl_nalu}}
  end

  # Calculate picture order count according to section 8.3.1 of the ITU-T H265 specification
  defp calculate_poc(:h265, vcl_nalu, state) do
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

  defp get_slice_type(vcl_nalu) do
    case vcl_nalu.parsed_fields do
      %{frame_mbs_only_flag: true} -> :frame
      %{field_pic_flag: false} -> :frame
      %{bottom_field_flag: true} -> :bottom_field
      _other -> :top_field
    end
  end
end
