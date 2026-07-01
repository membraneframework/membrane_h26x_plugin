defmodule Membrane.H265.AUSplitter do
  @moduledoc """
  Module providing functionalities to group H265 NAL units
  into access units.

  The access unit splitter's behaviour is based on section **7.4.2.4.4**
  *"Order of NAL units and coded pictures and association to access units"*
  of the *"ITU-T Rec. H.265 (08/2021)"* specification.
  """
  use Membrane.H26x.AUSplitter

  require Logger
  require Membrane.H265.NALuTypes, as: NALuTypes

  alias Membrane.H265.NALuTypes
  alias Membrane.H26x.{AUSplitter, NALu}

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
        Logger.warning("AUSplitter: Improper transition")
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
        Logger.warning("AUSplitter: Improper transition")
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
