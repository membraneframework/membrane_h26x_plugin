defmodule Membrane.H264.Parser.AUSplitter do
  @moduledoc """
  Module providing functionalities to divide the binary
  h264 stream into access units.

  The access unit splitter's behaviour is based on 7.4.1.2.3
  "Order of NAL units and coded pictures and association to access units"
  of the "ITU-T Rec. H.264 (01/2012)" specification. The most crucial part
  of the access unit splitter is the mechanism to detect new primary coded video picture.
  WARNING: Our implementation of that mechanism is based on:
  7.4.1.2.4 "Detection of the first VCL NAL unit of a primary coded picture"
  of the "ITU-T Rec. H.264 (01/2012)", however it adds one more
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
            access_units_to_output: access_unit_t()
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

  @non_vcl_nalus [:sps, :pps, :aud, :sei]
  @vcl_nalus [:idr, :non_idr, :part_a, :part_b, :part_c]

  @type access_unit_t() :: list(NALu.t())

  # split_nalus/2 defines a finite state machine with two states: :first and :second.
  # The state :first describes the state before reaching the primary coded picture NALu of a given access unit.
  # The state :second describes the state after processing the primary coded picture NALu of a given access unit.

  @doc """
  This function splits the given list of NAL units into the access units.

  It can be used when the access unit splitter is used for the stream
  which is not completly available at the time of function invoction,
  because apart from the list of access units the functions returns it's state,
  to be used in next invocation.
  When the whole stream is available at the invocation time, the use can use
  `split_binary_into_access_units/1`.
  Under the hood, `split_nalus/2` defines a finite state machine
  with two states: :first and :second. The state :first describes the state before
  reaching the primary coded picture NALu of a given access unit. The state :second
  describes the state after processing the primary coded picture NALu of a given
  access unit.
  """
  @spec split_nalus(list(NALu.t()), t()) :: {list(access_unit_t()), t()}
  def split_nalus(nalus, state)

  def split_nalus([first_nalu | rest_nalus], %{fsm_state: :first} = state) do
    cond do
      is_new_primary_coded_vcl_nalu(first_nalu, state.previous_primary_coded_picture_nalu) ->
        split_nalus(
          rest_nalus,
          %__MODULE__{
            state
            | nalus_acc: state.nalus_acc ++ [first_nalu],
              fsm_state: :second,
              previous_primary_coded_picture_nalu: first_nalu
          }
        )

      first_nalu.type in @non_vcl_nalus ->
        split_nalus(
          rest_nalus,
          %__MODULE__{state | nalus_acc: state.nalus_acc ++ [first_nalu]}
        )

      true ->
        raise "AUSplitter: Improper transition"
    end
  end

  def split_nalus([first_nalu | rest_nalus], %{fsm_state: :second} = state) do
    cond do
      first_nalu.type in @non_vcl_nalus ->
        split_nalus(
          rest_nalus,
          %__MODULE__{
            state
            | nalus_acc: [first_nalu],
              fsm_state: :first,
              access_units_to_output: state.access_units_to_output ++ [state.nalus_acc]
          }
        )

      is_new_primary_coded_vcl_nalu(first_nalu, state.previous_primary_coded_picture_nalu) ->
        split_nalus(
          rest_nalus,
          %__MODULE__{
            state
            | nalus_acc: [first_nalu],
              previous_primary_coded_picture_nalu: first_nalu,
              access_units_to_output: state.access_units_to_output ++ [state.nalus_acc]
          }
        )

      first_nalu.type in @vcl_nalus or first_nalu.type == :filler_data ->
        split_nalus(
          rest_nalus,
          %__MODULE__{state | nalus_acc: state.nalus_acc ++ [first_nalu]}
        )

      true ->
        raise "AUSplitter: Improper transition"
    end
  end

  def split_nalus([], state) do
    {state.access_units_to_output, %__MODULE__{state | access_units_to_output: []}}
  end

  @doc """
  Returns a list of NAL units which are hold in access unit splitter's state accumulator
  and sets that accumulator empty.

  These NAL units aren't proved to form a new access units and that is why they haven't yet been
  output by `split_nalus/2`.
  """
  @spec flush(t()) :: {list(NALu.t()), t()}
  def flush(state) do
    {state.nalus_acc, %{state | nalus_acc: []}}
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
end
