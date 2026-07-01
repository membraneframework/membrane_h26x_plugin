defmodule Membrane.H26x.AUSplitter do
  @moduledoc """
  A behaviour module to split NALus into access units
  """

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
