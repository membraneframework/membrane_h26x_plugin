defmodule Membrane.H264.Parser.AUSplitter do
  @moduledoc """
  Module providing functionalities to divide the binary
  h264 stream into access units.

  The access unit splitter's behaviour is based on *"7.4.1.2.3
  Order of NAL units and coded pictures and association to access units"*
  of the *"ITU-T Rec. H.264 (01/2012)"* specification. The most crucial part
  of the access unit splitter is the mechanism to detect new primary coded video picture.

  WARNING: Our implementation of that mechanism is based on:
  *"7.4.1.2.4 Detection of the first VCL NAL unit of a primary coded picture"*
  of the *"ITU-T Rec. H.264 (01/2012)"*, however it adds one more
  additional condition which, when satisfied, says that the given
  VCL NALu is a new primary coded picture. That condition is whether the picture
  is a keyframe or not.
  """
  require Membrane.Logger

  require Membrane.H264.Parser.NALuTypes, as: NALuTypes

  alias Membrane.H264.Parser.NALu

  @typedoc """
  A structure holding a state of the access unit splitter.
  """
  @opaque t :: %__MODULE__{
            nalus_acc: [NALu.t()],
            fsm_state: :first | :second,
            previous_primary_coded_picture_nalu: NALu.t() | nil,
            access_units_to_output: access_unit()
          }
  @enforce_keys [
    :nalus_acc,
    :fsm_state,
    :previous_primary_coded_picture_nalu,
    :access_units_to_output
  ]
  defstruct @enforce_keys

  @doc """
  Returns a structure holding a clear state of the
  access unit splitter.
  """
  @spec new() :: t()
  def new() do
    %__MODULE__{
      nalus_acc: [],
      fsm_state: :first,
      previous_primary_coded_picture_nalu: nil,
      access_units_to_output: []
    }
  end

  @non_vcl_nalu_types_at_au_beginning [:sps, :pps, :aud, :sei]
  @non_vcl_nalu_types_at_au_end [:end_of_seq, :end_of_stream]

  @typedoc """
  A type representing an access unit - a list of logically associated NAL units.
  """
  @type access_unit() :: list(NALu.t())

  @doc """
  Splits the given list of NAL units into the access units.

  It can be used for a stream which is not completely available at the time of function invocation,
  as the function updates the state of the access unit splitter - the function can
  be invoked once more, with new NAL units and the updated state.
  Under the hood, `split/2` defines a finite state machine
  with two states: `:first` and `:second`. The state `:first` describes the state before
  reaching the primary coded picture NALu of a given access unit. The state `:second`
  describes the state after processing the primary coded picture NALu of a given
  access unit.

  If `assume_au_aligned` flag is set to `true`, input is assumed to form a complete set
  of access units and therefore all of them are returned. Otherwise, the last access unit
  is not returned until another access unit starts, as it's the only way to prove that
  the access unit is complete.
  """
  @spec split([NALu.t()], boolean(), t()) :: {[access_unit()], t()}
  def split(nalus, assume_au_aligned \\ false, state) do
    state = do_split(nalus, state)

    {aus, state} =
      if assume_au_aligned do
        {state.access_units_to_output ++ [state.nalus_acc],
         %__MODULE__{state | access_units_to_output: [], nalus_acc: []}}
      else
        {state.access_units_to_output, %__MODULE__{state | access_units_to_output: []}}
      end

    {Enum.reject(aus, &Enum.empty?/1), state}
  end

  defp do_split([first_nalu | rest_nalus], %{fsm_state: :first} = state) do
    cond do
      is_new_primary_coded_vcl_nalu(first_nalu, state.previous_primary_coded_picture_nalu) ->
        do_split(
          rest_nalus,
          %__MODULE__{
            state
            | nalus_acc: state.nalus_acc ++ [first_nalu],
              fsm_state: :second,
              previous_primary_coded_picture_nalu: first_nalu
          }
        )

      first_nalu.type in @non_vcl_nalu_types_at_au_beginning ->
        do_split(
          rest_nalus,
          %__MODULE__{state | nalus_acc: state.nalus_acc ++ [first_nalu]}
        )

      true ->
        Membrane.Logger.warning("AUSplitter: Improper transition, first_nalu: #{inspect(first_nalu)}")
        state
    end
  end

  defp do_split([first_nalu | rest_nalus], %{fsm_state: :second} = state) do
    cond do
      first_nalu.type in @non_vcl_nalu_types_at_au_end ->
        do_split(
          rest_nalus,
          %__MODULE__{
            state
            | nalus_acc: state.nalus_acc ++ [first_nalu]
          }
        )

      first_nalu.type in @non_vcl_nalu_types_at_au_beginning ->
        do_split(
          rest_nalus,
          %__MODULE__{
            state
            | nalus_acc: [first_nalu],
              fsm_state: :first,
              access_units_to_output: state.access_units_to_output ++ [state.nalus_acc]
          }
        )

      is_new_primary_coded_vcl_nalu(first_nalu, state.previous_primary_coded_picture_nalu) ->
        do_split(
          rest_nalus,
          %__MODULE__{
            state
            | nalus_acc: [first_nalu],
              previous_primary_coded_picture_nalu: first_nalu,
              access_units_to_output: state.access_units_to_output ++ [state.nalus_acc]
          }
        )

      NALuTypes.is_vcl_nalu_type(first_nalu.type) or first_nalu.type == :filler_data ->
        do_split(
          rest_nalus,
          %__MODULE__{state | nalus_acc: state.nalus_acc ++ [first_nalu]}
        )

      true ->
        Membrane.Logger.warning("AUSplitter: Improper transition, first_nalu: #{inspect(first_nalu)}")
        state
    end
  end

  defp do_split([], state) do
    state
  end

  # Reference source for the behaviour below:
  # https://github.com/GStreamer/gst-plugins-bad/blob/ca8068c6d793d7aaa6f2e2cc6324fdedfe2f33fa/gst/videoparsers/gsth264parse.c#L1183C45-L1185C49
  #
  # NOTE: The following check is not a part of the original H264 specification unlike the other checks below.
  #
  # It happens that some streams have broken frame numbers (that are either non-monotically
  # increasing or just reset on a key frame) but the `first_mb_in_slice` set to zero can mean that
  # we are dealin with a new AU (given a proper `nal_unit_type`). It seems that it is sufficient
  # condition to check for `first_mb_in_slice` set to zero to detect a new AU.
  defguardp first_mb_in_slice_zero(a)
            when a.first_mb_in_slice == 0 and
                   a.nal_unit_type in [1, 2, 5]

  defguardp frame_num_differs(a, b) when a.frame_num != b.frame_num

  defguardp pic_parameter_set_id_differs(a, b)
            when a.pic_parameter_set_id != b.pic_parameter_set_id

  defguardp field_pic_flag_differs(a, b) when a.field_pic_flag != b.field_pic_flag

  defguardp bottom_field_flag_differs(a, b) when a.bottom_field_flag != b.bottom_field_flag

  defguardp nal_ref_idc_differs_one_zero(a, b)
            when (a.nal_ref_idc == 0 or b.nal_ref_idc == 0) and
                   a.nal_ref_idc != b.nal_ref_idc

  defguardp pic_order_cnt_zero_check(a, b)
            when a.pic_order_cnt_type == 0 and b.pic_order_cnt_type == 0 and
                   (a.pic_order_cnt_lsb != b.pic_order_cnt_lsb or
                      a.delta_pic_order_cnt_bottom != b.delta_pic_order_cnt_bottom)

  defguardp pic_order_cnt_one_check_zero(a, b)
            when a.pic_order_cnt_type == 1 and b.pic_order_cnt_type == 1 and
                   hd(a.delta_pic_order_cnt) != hd(b.delta_pic_order_cnt)

  defguardp pic_order_cnt_one_check_one(a, b)
            when a.pic_order_cnt_type == 1 and b.pic_order_cnt_type == 1 and
                   hd(hd(a.delta_pic_order_cnt)) != hd(hd(b.delta_pic_order_cnt))

  defguardp idr_and_non_idr(a, b)
            when (a.nal_unit_type == 5 or b.nal_unit_type == 5) and
                   a.nal_unit_type != b.nal_unit_type

  defguardp idrs_with_idr_pic_id_differ(a, b)
            when a.nal_unit_type == 5 and b.nal_unit_type == 5 and a.idr_pic_id != b.idr_pic_id

  defp is_new_primary_coded_vcl_nalu(%{type: type}, _last_nalu)
       when not NALuTypes.is_vcl_nalu_type(type),
       do: false

  defp is_new_primary_coded_vcl_nalu(_nalu, nil), do: true

  # Conditions based on 7.4.1.2.4 "Detection of the first VCL NAL unit of a primary coded picture"
  # of the "ITU-T Rec. H.264 (01/2012)"
  defp is_new_primary_coded_vcl_nalu(%{parsed_fields: nalu}, %{parsed_fields: last_nalu})
       when first_mb_in_slice_zero(nalu)
       when frame_num_differs(nalu, last_nalu)
       when pic_parameter_set_id_differs(nalu, last_nalu)
       when field_pic_flag_differs(nalu, last_nalu)
       when bottom_field_flag_differs(nalu, last_nalu)
       when nal_ref_idc_differs_one_zero(nalu, last_nalu)
       when pic_order_cnt_zero_check(nalu, last_nalu)
       when pic_order_cnt_one_check_zero(nalu, last_nalu)
       when pic_order_cnt_one_check_one(nalu, last_nalu)
       when idr_and_non_idr(nalu, last_nalu)
       when idrs_with_idr_pic_id_differ(nalu, last_nalu) do
    true
  end

  defp is_new_primary_coded_vcl_nalu(_nalu, _last_nalu) do
    false
  end
end
