defmodule Membrane.H26x.ParsingEngine.ParameterSetCache do
  @moduledoc false

  # Tracks the parameter set NALus (VPS/SPS/PPS) of a stream, keyed by their type
  # and id, and decides which of them should be attached to an access unit. A
  # parameter set redefined under an already used id replaces the cached one, so
  # the cache always holds only the currently active set per id, in the order in
  # which the ids first appeared.

  alias Membrane.H26x.NALu

  @parameter_set_types [:vps, :sps, :pps]

  @enforce_keys [:repeat_parameter_sets]
  defstruct @enforce_keys ++ [active: [], pending: []]

  @type t :: %__MODULE__{
          repeat_parameter_sets: boolean(),
          active: [NALu.t()],
          pending: [NALu.t()]
        }

  @spec new(boolean()) :: t()
  def new(repeat_parameter_sets) do
    %__MODULE__{repeat_parameter_sets: repeat_parameter_sets}
  end

  @spec parameter_set?(NALu.t()) :: boolean()
  def parameter_set?(nalu), do: nalu.type in @parameter_set_types

  @spec put(t(), [NALu.t()]) :: t()
  def put(cache, nalus) do
    nalus
    |> Enum.filter(&parameter_set?/1)
    |> Enum.reduce(cache, fn new_ps, cache ->
      # A parameter set put again unchanged is pending as well, so that a stream repeating its parameter sets keeps them.
      %{cache | active: upsert(cache.active, new_ps), pending: upsert(cache.pending, new_ps)}
    end)
  end

  @doc """
  Returns the parameter sets to attach to the next output access unit: the ones put since
  the previous call, or all the active ones for a keyframe when repeating is enabled.
  """
  @spec take(t(), keyframe? :: boolean()) :: {[NALu.t()], t()}
  def take(cache, keyframe?) do
    parameter_sets =
      if cache.repeat_parameter_sets and keyframe?, do: cache.active, else: cache.pending

    {parameter_sets, %{cache | pending: []}}
  end

  defp upsert(parameter_sets, new_ps) do
    case Enum.find_index(parameter_sets, &(parameter_set_id(&1) == parameter_set_id(new_ps))) do
      nil -> parameter_sets ++ [new_ps]
      index -> List.replace_at(parameter_sets, index, new_ps)
    end
  end

  defp parameter_set_id(%NALu{type: type, parsed_fields: fields}) do
    case type do
      :vps -> {:vps, fields.video_parameter_set_id}
      :sps -> {:sps, fields.seq_parameter_set_id}
      :pps -> {:pps, fields.pic_parameter_set_id}
    end
  end
end
