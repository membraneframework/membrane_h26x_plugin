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
  alias Membrane.H264.Parser.NALu

  @typedoc """
  A structure holding a state of the access unit splitter.
  """
  @opaque t :: %__MODULE__{
            nalus_acc: [NALu.t()],
            fsm_state: :first | :second,
            previous_primary_coded_picture_nalu: NALu.t() | nil,
            access_units_to_output: access_unit_t(),
            prevPicOrderCntMsb: integer(),
            pocs: list(integer())
          }
  @enforce_keys [
    :nalus_acc,
    :fsm_state,
    :previous_primary_coded_picture_nalu,
    :access_units_to_output,
    :prevPicOrderCntMsb,
    :pocs
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
      access_units_to_output: [],
      prevPicOrderCntMsb: 0,
      pocs: []
    }
  end

  @non_vcl_nalus [:sps, :pps, :aud, :sei]
  @vcl_nalus [:idr, :non_idr, :part_a, :part_b, :part_c]

  @typedoc """
  A type representing an access unit - a list of logically associated NAL units.
  """
  @type access_unit_t() :: list(NALu.t())

  # split/2 defines a finite state machine with two states: :first and :second.
  # The state :first describes the state before reaching the primary coded picture NALu of a given access unit.
  # The state :second describes the state after processing the primary coded picture NALu of a given access unit.

  @doc """
  Splits the given list of NAL units into the access units.

  It can be used for a stream which is not completly available at the time of function invoction,
  as the function updates the state of the access unit splitter - the function can
  be invoked once more, with new NAL units and the updated state.
  Under the hood, `split/2` defines a finite state machine
  with two states: `:first` and `:second`. The state `:first` describes the state before
  reaching the primary coded picture NALu of a given access unit. The state `:second`
  describes the state after processing the primary coded picture NALu of a given
  access unit.
  """
  @spec split(list(NALu.t()), t()) :: {list({access_unit_t(), integer()}), t()}
  def split(nalus, state)

  def split([first_nalu | rest_nalus], %{fsm_state: :first} = state) do
    cond do
      is_new_primary_coded_vcl_nalu(first_nalu, state.previous_primary_coded_picture_nalu) ->
        {poc, state} = calculate_poc(first_nalu, state.previous_primary_coded_picture_nalu, state)

        split(
          rest_nalus,
          %__MODULE__{
            state
            | nalus_acc: state.nalus_acc ++ [first_nalu],
              fsm_state: :second,
              previous_primary_coded_picture_nalu: first_nalu,
              pocs: state.pocs ++ [poc]
          }
        )

      first_nalu.type in @non_vcl_nalus ->
        split(
          rest_nalus,
          %__MODULE__{state | nalus_acc: state.nalus_acc ++ [first_nalu]}
        )

      true ->
        raise "AUSplitter: Improper transition"
    end
  end

  def split([first_nalu | rest_nalus], %{fsm_state: :second} = state) do
    cond do
      first_nalu.type in @non_vcl_nalus ->
        split(
          rest_nalus,
          %__MODULE__{
            state
            | nalus_acc: [first_nalu],
              fsm_state: :first,
              access_units_to_output: state.access_units_to_output ++ [state.nalus_acc]
          }
        )

      is_new_primary_coded_vcl_nalu(first_nalu, state.previous_primary_coded_picture_nalu) ->
        {poc, state} = calculate_poc(first_nalu, state.previous_primary_coded_picture_nalu, state)

        split(
          rest_nalus,
          %__MODULE__{
            state
            | nalus_acc: [first_nalu],
              previous_primary_coded_picture_nalu: first_nalu,
              access_units_to_output: state.access_units_to_output ++ [state.nalus_acc],
              pocs: state.pocs ++ [poc]
          }
        )

      first_nalu.type in @vcl_nalus or first_nalu.type == :filler_data ->
        split(
          rest_nalus,
          %__MODULE__{state | nalus_acc: state.nalus_acc ++ [first_nalu]}
        )

      true ->
        raise "AUSplitter: Improper transition"
    end
  end

  def split([], state) do
    new_pocs =
      if length(state.access_units_to_output) == length(state.pocs),
        do: [],
        else: [Enum.at(state.pocs, -1)]

    {Enum.zip(state.access_units_to_output, state.pocs) |> Enum.filter(&(&1 |> elem(0) != [])),
     %__MODULE__{state | access_units_to_output: [], pocs: new_pocs}}
  end

  @doc """
  Returns a list of NAL units which are hold in access unit splitter's state accumulator
  and sets that accumulator empty.

  These NAL units aren't proved to form a new access units and that is why they haven't yet been
  output by `Membrane.H264.Parser.AUSplitter.split/2`.
  """
  @spec flush(t()) :: {{list(NALu.t()), integer()}, t()}
  def flush(state) do
    if length(state.pocs) != 1,
      do: raise("Improper pocs length #{length(state.pocs)} #{inspect(state.nalus_acc)}")

    poc = state.pocs |> Enum.at(0)
    {{state.nalus_acc, poc}, %{state | nalus_acc: [], pocs: []}}
  end

  # credo has been disabled since I believe that cyclomatic complexity of this function, though large, doesn't imply
  # that the function is unreadible - in fact, what the function does, is simply checking the sequence of conditions, as
  # specified in the documentation
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp is_new_primary_coded_vcl_nalu(nalu, last_nalu) do
    # See: 7.4.1.2.4 "Detection of the first VCL NAL unit of a primary coded picture"
    # of the "ITU-T Rec. H.264 (01/2012)"

    if nalu.type in @vcl_nalus do
      cond do
        last_nalu == nil ->
          true

        # in case of a nalu holding the keyframe, return true
        # this one wasn't specified in the documentation, however it seems logical to do so
        # and not doing that has made the application crash

        nalu.type == :idr ->
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

        # The following condition to be checked is also specified in the documentation: "IdrPicFlag is equal to 1 for
        # both and idr_pic_id differs in value".
        # At the same time, it seems that it describes the situation, that we are having two different IDR frames - and
        # that should imply, that their frame_num should differ, which is already checked in the second condition

        true ->
          false
      end
    else
      false
    end
  end

  defp calculate_poc(vcl_nalu, previous_vcl_nalu, state) do
    case vcl_nalu.parsed_fields.pic_order_cnt_type do
      0 ->
        maxPicOrderCntLsb =
          :math.pow(2, vcl_nalu.parsed_fields.log2_max_pic_order_cnt_lsb_minus4 + 4) |> round()

        slice_type = get_slice_type(vcl_nalu)

        {prevPicOrderCntMsb, prevPicOrderCntLsb} =
          if vcl_nalu.type == :idr do
            {0, 0}
          else
            {state.prevPicOrderCntMsb, previous_vcl_nalu.parsed_fields.pic_order_cnt_lsb}
          end

        pic_order_cnt_lsb = vcl_nalu.parsed_fields.pic_order_cnt_lsb

        picOrderCntMsb =
          cond do
            pic_order_cnt_lsb < prevPicOrderCntLsb and
                prevPicOrderCntLsb - pic_order_cnt_lsb >= maxPicOrderCntLsb / 2 ->
              prevPicOrderCntMsb + maxPicOrderCntLsb

            pic_order_cnt_lsb > prevPicOrderCntLsb &&
                pic_order_cnt_lsb - prevPicOrderCntLsb > maxPicOrderCntLsb / 2 ->
              prevPicOrderCntMsb - maxPicOrderCntLsb

            true ->
              prevPicOrderCntMsb
          end

        topFieldOrderCnt =
          if slice_type != :bottom_field do
            picOrderCntMsb + pic_order_cnt_lsb
          end

        bottomFieldOrderCnt =
          if slice_type == :bottom_field do
            topFieldOrderCnt + vcl_nalu.parsed_fields.delta_pic_order_cnt_bottom
          else
            if slice_type == :frame do
              picOrderCntMsb + pic_order_cnt_lsb
            end
          end

        picOrderCnt =
          case slice_type do
            :frame -> min(topFieldOrderCnt, bottomFieldOrderCnt)
            :top_field -> topFieldOrderCnt
            :bottom_field -> bottomFieldOrderCnt
          end

        {picOrderCnt, %{state | prevPicOrderCntMsb: picOrderCntMsb}}

      1 ->
        raise "not yet supported"

      2 ->
        {vcl_nalu.parsed_fields.frame_num, state}
    end
  end

  defp get_slice_type(vcl_nalu) do
    if vcl_nalu.parsed_fields.frame_mbs_only_flag do
      :frame
    else
      if vcl_nalu.parsed_fields.field_pic_flag do
        if vcl_nalu.parsed_fields.bottom_field_flag do
          :bottom_field
        else
          :top_field
        end
      else
        :frame
      end
    end
  end
end
