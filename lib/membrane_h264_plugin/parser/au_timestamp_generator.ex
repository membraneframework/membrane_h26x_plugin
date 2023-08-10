defmodule Membrane.H264.Parser.AUTimestampGenerator do
  @moduledoc false

  require Membrane.H264.Parser.NALuTypes, as: NALuTypes

  alias Membrane.H264.Parser.NALu

  @type t :: %{
          au_counter: non_neg_integer(),
          key_frame_au_idx: non_neg_integer(),
          prev_pic_first_vcl_nalu: NALu.t() | nil,
          prev_pic_order_cnt_msb: integer()
        }

  @spec new() :: t
  def new() do
    %{
      au_counter: 0,
      key_frame_au_idx: 0,
      prev_pic_first_vcl_nalu: nil,
      prev_pic_order_cnt_msb: 0
    }
  end

  @spec generate_ts_with_constant_framerate(
          [NALu.t()],
          framerate :: {frames :: pos_integer(), seconds :: pos_integer()},
          max_frame_reorder :: non_neg_integer(),
          t
        ) :: {{pts :: non_neg_integer(), dts :: non_neg_integer()}, t}
  def generate_ts_with_constant_framerate(au, {frames, seconds}, max_frame_reorder, state) do
    %{au_counter: au_counter, key_frame_au_idx: key_frame_au_idx} = state
    first_vcl_nalu = Enum.find(au, &NALuTypes.is_vcl_nalu_type(&1.type))
    {poc, state} = calculate_poc(first_vcl_nalu, state)
    key_frame_au_idx = if poc == 0, do: au_counter, else: key_frame_au_idx
    pts = div((key_frame_au_idx + poc) * seconds * Membrane.Time.second(), frames)
    dts = div((au_counter - max_frame_reorder) * seconds * Membrane.Time.second(), frames)

    state = %{
      state
      | au_counter: au_counter + 1,
        key_frame_au_idx: key_frame_au_idx,
        prev_pic_first_vcl_nalu: first_vcl_nalu
    }

    {{pts, dts}, state}
  end

  # Calculate picture order count according to section 8.2.1 of the ITU-T H264 specification
  defp calculate_poc(%{parsed_fields: %{pic_order_cnt_type: 0}} = vcl_nalu, state) do
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

    {div(pic_order_cnt, 2), %{state | prev_pic_order_cnt_msb: pic_order_cnt_msb}}
  end

  defp calculate_poc(%{parsed_fields: %{pic_order_cnt_type: 1}}, _state) do
    raise "Timestamp generation error: unsupported stream. Unsupported field value pic_order_cnt_type=1"
  end

  defp calculate_poc(%{parsed_fields: %{pic_order_cnt_type: 2, frame_num: frame_num}}, state) do
    {frame_num, state}
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
