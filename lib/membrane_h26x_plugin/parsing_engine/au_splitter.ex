defmodule Membrane.H26x.ParsingEngine.AUSplitter do
  @moduledoc false
  # A behaviour module to split NALus into access units

  alias Membrane.H26x.NALu

  @typedoc """
  A type representing an access unit - a list of logically associated NAL units.
  """
  @type access_unit() :: list(NALu.t())

  @typedoc """
  A structure holding a state of the access unit splitter.
  """
  @opaque t :: %__MODULE__{
            nalus_acc: [NALu.t()],
            fsm_state: :first | :second,
            previous_nalu: NALu.t() | nil,
            access_units_to_output: [access_unit()]
          }

  @enforce_keys [
    :nalus_acc,
    :fsm_state,
    :previous_nalu,
    :access_units_to_output
  ]
  defstruct @enforce_keys

  @doc """
  Feeds NAL units through the codec's access-unit-detection state machine,
  accumulating completed access units in the returned state.
  """
  @callback split([NALu.t()], t()) :: t()

  @doc """
  Returns a structure holding a clear state of the
  access unit splitter.
  """
  @spec new() :: t()
  def new() do
    %__MODULE__{
      nalus_acc: [],
      fsm_state: :first,
      previous_nalu: nil,
      access_units_to_output: []
    }
  end

  @doc """
  Splits the given list of NAL units into the access units.
  """
  @spec split(module(), [NALu.t()], boolean(), t()) :: {[access_unit()], t()}
  def split(module, nalus, assume_au_aligned \\ false, state) do
    %__MODULE__{} = state = module.split(nalus, state)

    {aus, state} =
      if assume_au_aligned do
        {state.access_units_to_output ++ [state.nalus_acc],
         %__MODULE__{state | access_units_to_output: [], nalus_acc: []}}
      else
        {state.access_units_to_output, %__MODULE__{state | access_units_to_output: []}}
      end

    {Enum.reject(aus, &Enum.empty?/1), state}
  end
end

defmodule Membrane.H264.AUSplitter do
  @moduledoc false
  # Module providing functionalities to divide the binary
  # h264 stream into access units.
  #
  # The access unit splitter's behaviour is based on *"7.4.1.2.3
  # Order of NAL units and coded pictures and association to access units"*
  # of the *"ITU-T Rec. H.264 (01/2012)"* specification. The most crucial part
  # of the access unit splitter is the mechanism to detect new primary coded video picture.
  #
  # WARNING: Our implementation of that mechanism is based on:
  # *"7.4.1.2.4 Detection of the first VCL NAL unit of a primary coded picture"*
  # of the *"ITU-T Rec. H.264 (01/2012)"*, however it adds one more
  # additional condition which, when satisfied, says that the given
  # VCL NALu is a new primary coded picture. That condition is whether the picture
  # is a keyframe or not.

  @behaviour Membrane.H26x.ParsingEngine.AUSplitter

  require Membrane.Logger

  require Membrane.H264.NALuTypes, as: NALuTypes

  alias Membrane.H26x.ParsingEngine.AUSplitter

  @non_vcl_nalu_types_at_au_beginning [:sps, :pps, :aud, :sei]
  @non_vcl_nalu_types_at_au_end [:end_of_seq, :end_of_stream]

  @impl true
  def split([first_nalu | rest_nalus], %AUSplitter{fsm_state: :first} = state) do
    cond do
      new_primary_coded_vcl_nalu?(first_nalu, state.previous_nalu) ->
        split(
          rest_nalus,
          %AUSplitter{
            state
            | nalus_acc: state.nalus_acc ++ [first_nalu],
              fsm_state: :second,
              previous_nalu: first_nalu
          }
        )

      first_nalu.type in @non_vcl_nalu_types_at_au_beginning ->
        split(
          rest_nalus,
          %AUSplitter{state | nalus_acc: state.nalus_acc ++ [first_nalu]}
        )

      true ->
        Membrane.Logger.warning(
          "AUSplitter: Improper transition, discarding NALu: #{inspect(first_nalu)}"
        )

        split(rest_nalus, state)
    end
  end

  def split([first_nalu | rest_nalus], %AUSplitter{fsm_state: :second} = state) do
    cond do
      first_nalu.type in @non_vcl_nalu_types_at_au_end ->
        split(
          rest_nalus,
          %AUSplitter{
            state
            | nalus_acc: state.nalus_acc ++ [first_nalu]
          }
        )

      first_nalu.type in @non_vcl_nalu_types_at_au_beginning ->
        split(
          rest_nalus,
          %AUSplitter{
            state
            | nalus_acc: [first_nalu],
              fsm_state: :first,
              access_units_to_output: state.access_units_to_output ++ [state.nalus_acc]
          }
        )

      new_primary_coded_vcl_nalu?(first_nalu, state.previous_nalu) ->
        split(
          rest_nalus,
          %AUSplitter{
            state
            | nalus_acc: [first_nalu],
              previous_nalu: first_nalu,
              access_units_to_output: state.access_units_to_output ++ [state.nalus_acc]
          }
        )

      NALuTypes.is_vcl_nalu_type(first_nalu.type) or first_nalu.type == :filler_data ->
        split(
          rest_nalus,
          %AUSplitter{state | nalus_acc: state.nalus_acc ++ [first_nalu]}
        )

      true ->
        Membrane.Logger.warning(
          "AUSplitter: Improper transition, discarding NALu: #{inspect(first_nalu)}"
        )

        split(rest_nalus, state)
    end
  end

  def split([], state) do
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

  defp new_primary_coded_vcl_nalu?(%{type: type}, _last_nalu)
       when not NALuTypes.is_vcl_nalu_type(type),
       do: false

  defp new_primary_coded_vcl_nalu?(_nalu, nil), do: true

  # Conditions based on 7.4.1.2.4 "Detection of the first VCL NAL unit of a primary coded picture"
  # of the "ITU-T Rec. H.264 (01/2012)"
  defp new_primary_coded_vcl_nalu?(%{parsed_fields: nalu}, %{parsed_fields: last_nalu})
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

  defp new_primary_coded_vcl_nalu?(_nalu, _last_nalu) do
    false
  end
end

defmodule Membrane.H265.AUSplitter do
  @moduledoc false
  # Module providing functionalities to group H265 NAL units
  # into access units.
  #
  # The access unit splitter's behaviour is based on section **7.4.2.4.4**
  # *"Order of NAL units and coded pictures and association to access units"*
  # of the *"ITU-T Rec. H.265 (08/2021)"* specification.

  @behaviour Membrane.H26x.ParsingEngine.AUSplitter

  require Logger
  require Membrane.H265.NALuTypes, as: NALuTypes

  alias Membrane.H265.NALuTypes
  alias Membrane.H26x.NALu
  alias Membrane.H26x.ParsingEngine.AUSplitter

  @non_vcl_nalus_at_au_beginning [:vps, :sps, :pps, :prefix_sei]
  @non_vcl_nalus_at_au_end [:fd, :eos, :eob, :suffix_sei]

  @impl true
  def split([first_nalu | rest_nalus], %AUSplitter{fsm_state: :first} = state) do
    cond do
      access_unit_first_slice_segment?(first_nalu) ->
        split(
          rest_nalus,
          %AUSplitter{
            state
            | nalus_acc: state.nalus_acc ++ [first_nalu],
              fsm_state: :second,
              previous_nalu: first_nalu
          }
        )

      (first_nalu.type == :aud and state.nalus_acc == []) or
        first_nalu.type in @non_vcl_nalus_at_au_beginning or
        NALu.int_type(first_nalu) in 41..44 or
          NALu.int_type(first_nalu) in 48..55 ->
        split(
          rest_nalus,
          %AUSplitter{state | nalus_acc: state.nalus_acc ++ [first_nalu]}
        )

      true ->
        Logger.warning("AUSplitter: Improper transition, discarding NALu: #{inspect(first_nalu)}")
        split(rest_nalus, state)
    end
  end

  def split([first_nalu | rest_nalus], %AUSplitter{fsm_state: :second} = state) do
    previous_nalu = state.previous_nalu

    cond do
      first_nalu.type == :aud or first_nalu.type in @non_vcl_nalus_at_au_beginning ->
        split(
          rest_nalus,
          %AUSplitter{
            state
            | nalus_acc: [first_nalu],
              fsm_state: :first,
              access_units_to_output: state.access_units_to_output ++ [state.nalus_acc]
          }
        )

      access_unit_first_slice_segment?(first_nalu) ->
        split(
          rest_nalus,
          %AUSplitter{
            state
            | nalus_acc: [first_nalu],
              previous_nalu: first_nalu,
              access_units_to_output: state.access_units_to_output ++ [state.nalus_acc]
          }
        )

      first_nalu.type == previous_nalu.type or
        first_nalu.type in @non_vcl_nalus_at_au_end or
        NALu.int_type(first_nalu) in 45..47 or
          NALu.int_type(first_nalu) in 56..63 ->
        split(
          rest_nalus,
          %AUSplitter{
            state
            | nalus_acc: state.nalus_acc ++ [first_nalu],
              previous_nalu: first_nalu
          }
        )

      true ->
        Logger.warning("AUSplitter: Improper transition, discarding NALu: #{inspect(first_nalu)}")
        split(rest_nalus, state)
    end
  end

  def split([], state) do
    state
  end

  defp access_unit_first_slice_segment?(nalu) do
    NALuTypes.is_vcl_nalu_type(nalu.type) and
      nalu.parsed_fields[:first_slice_segment_in_pic_flag] == 1
  end
end
