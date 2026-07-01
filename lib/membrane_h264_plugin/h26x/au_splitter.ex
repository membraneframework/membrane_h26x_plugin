defmodule Membrane.H26x.AUSplitter do
  @moduledoc """
  A behaviour module to split NALus into access units.

  The codec-specific modules that `use Membrane.H26x.AUSplitter` are only required to
  implement the `c:do_split/2` callback, which drives the finite state machine detecting
  the access unit boundaries. The generic bookkeeping (state struct, `new/0` and the
  `split/3` wrapper) is provided by this module.
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

  @doc """
  Feeds the given list of NAL units through the codec-specific finite state machine,
  returning the updated splitter state.
  """
  @callback split([NALu.t()], t()) :: t()

  defmacro __using__(_options) do
    quote location: :keep do
      @behaviour unquote(__MODULE__)

      alias Membrane.H26x.AUSplitter

      @spec new() :: AUSplitter.t()
      defdelegate new(), to: AUSplitter

      # No default on `assume_au_aligned`, as it would generate a `split/2` head
      # that would clash with the `c:Membrane.H26x.AUSplitter.split/2` callback.
      @spec split([Membrane.H26x.NALu.t()], boolean(), AUSplitter.t()) ::
              {[AUSplitter.access_unit()], AUSplitter.t()}
      def split(nalus, assume_au_aligned, state) do
        AUSplitter.split(__MODULE__, nalus, assume_au_aligned, state)
      end
    end
  end

  @doc """
  Returns a structure holding a clear state of the access unit splitter.
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

  It can be used for a stream which is not completely available at the time of function invocation,
  as the function updates the state of the access unit splitter - the function can
  be invoked once more, with new NAL units and the updated state.
  Under the hood, the codec-specific `c:split/2` defines a finite state machine
  with two states: `:first` and `:second`. The state `:first` describes the state before
  reaching the primary coded picture NALu of a given access unit. The state `:second`
  describes the state after processing the primary coded picture NALu of a given
  access unit.

  If `assume_au_aligned` flag is set to `true`, input is assumed to form a complete set
  of access units and therefore all of them are returned. Otherwise, the last access unit
  is not returned until another access unit starts, as it's the only way to prove that
  the access unit is complete.
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
