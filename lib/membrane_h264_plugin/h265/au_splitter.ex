defmodule Membrane.H265.AUSplitter do
  @moduledoc """
  Module providing functionalities to group H265 NAL units
  into access units.

  The access unit splitter's behaviour is based on section **7.4.2.4.4**
  *"Order of NAL units and coded pictures and association to access units"*
  of the *"ITU-T Rec. H.265 (08/2021)"* specification.
  """
  @behaviour Membrane.H2645.AUSplitter

  require Logger

  alias Membrane.H2645.{AUSplitter, NALu}
  alias Membrane.H265.NALuTypes

  @typedoc """
  A structure holding a state of the access unit splitter.
  """
  @opaque t :: %__MODULE__{
            nalus_acc: [NALu.t()],
            fsm_state: :first | :second,
            previous_nalu: NALu.t() | nil,
            access_units_to_output: [AUSplitter.access_unit()]
          }

  @enforce_keys [
    :nalus_acc,
    :fsm_state,
    :previous_nalu,
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
      previous_nalu: nil,
      access_units_to_output: []
    }
  end

  @vcl_nalus NALuTypes.vcl_nalu_types()
  @non_vcl_nalus_at_au_beginning [:vps, :sps, :pps, :prefix_sei]
  @non_vcl_nalus_at_au_end [:fd, :eos, :eob, :suffix_sei]

  @doc """
  Splits the given list of NAL units into the access units.

  It can be used for a stream which is not completely available at the time of function invocation,
  as the function updates the state of the access unit splitter - the function can
  be invoked once more, with new NAL units and the updated state.
  Under the hood, `split/2` defines a finite state machine
  with two states: `:first` and `:second`. The state `:first` describes the state before
  reaching the first segment of a coded picture NALu of a given access unit. The state `:second`
  describes the state after processing the first segment of the coded picture of a given
  access unit.
  """
  @spec split([NALu.t()], boolean(), t()) :: {[AUSplitter.access_unit()], t()}
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
      access_unit_first_slice_segment?(first_nalu) ->
        do_split(
          rest_nalus,
          %__MODULE__{
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
        do_split(
          rest_nalus,
          %__MODULE__{state | nalus_acc: state.nalus_acc ++ [first_nalu]}
        )

      true ->
        Logger.warning("AUSplitter: Improper transition")
        do_split(rest_nalus, state)
    end
  end

  defp do_split([first_nalu | rest_nalus], %{fsm_state: :second} = state) do
    previous_nalu = state.previous_nalu

    cond do
      first_nalu.type == :aud or first_nalu.type in @non_vcl_nalus_at_au_beginning ->
        do_split(
          rest_nalus,
          %__MODULE__{
            state
            | nalus_acc: [first_nalu],
              fsm_state: :first,
              access_units_to_output: state.access_units_to_output ++ [state.nalus_acc]
          }
        )

      access_unit_first_slice_segment?(first_nalu) ->
        do_split(
          rest_nalus,
          %__MODULE__{
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
        do_split(
          rest_nalus,
          %__MODULE__{
            state
            | nalus_acc: state.nalus_acc ++ [first_nalu],
              previous_nalu: first_nalu
          }
        )

      true ->
        Logger.warning("AUSplitter: Improper transition")
        do_split(rest_nalus, state)
    end
  end

  defp do_split([], state) do
    state
  end

  defp access_unit_first_slice_segment?(nalu) do
    nalu.type in @vcl_nalus and
      nalu.parsed_fields[:first_slice_segment_in_pic_flag] == 1
  end
end
