defmodule Membrane.H26x.ParsingEngine.ParameterSetCache do
  @moduledoc false

  # Tracks the parameter set NALus (VPS/SPS/PPS) of a stream, keyed by their type
  # and id, and decides which of them should be attached to an access unit. A
  # parameter set redefined under an already used id replaces the cached one, so
  # the cache always holds only the currently active set per id, in the order in
  # which the ids first appeared.

  alias Membrane.H26x.{NALu, ParsingEngine}

  @parameter_set_types [:vps, :sps, :pps]

  @enforce_keys [:repeat_parameter_sets, :out_of_band?]
  defstruct @enforce_keys ++ [active: [], pending: []]

  @type t :: %__MODULE__{
          repeat_parameter_sets: boolean(),
          out_of_band?: boolean(),
          active: [NALu.t()],
          pending: [NALu.t()]
        }

  @spec new(boolean(), ParsingEngine.stream_structure()) :: t()
  def new(repeat_parameter_sets, output_stream_structure) do
    %__MODULE__{
      repeat_parameter_sets: repeat_parameter_sets,
      out_of_band?: out_of_band?(output_stream_structure)
    }
  end

  @spec parameter_set?(NALu.t()) :: boolean()
  def parameter_set?(nalu) do
    nalu.type in @parameter_set_types
  end

  @spec put(t(), [NALu.t()]) :: t()
  def put(cache, nalus) do
    nalus
    |> Enum.filter(&parameter_set?/1)
    |> Enum.reduce(cache, fn new_ps, cache ->
      %{cache | active: upsert(cache.active, new_ps), pending: upsert(cache.pending, new_ps)}
    end)
  end

  @doc """
  Returns the parameter sets to attach to the next output access unit: the ones put since
  the previous call, or all the active ones for a keyframe when repeating is enabled.
  None are returned when the output stream structure carries them out-of-band.
  """
  @spec take(t(), keyframe? :: boolean()) :: {[NALu.t()], t()}
  def take(cache, keyframe?) do
    parameter_sets =
      cond do
        cache.out_of_band? -> []
        cache.repeat_parameter_sets and keyframe? -> cache.active
        true -> cache.pending
      end

    {parameter_sets, %{cache | pending: []}}
  end

  defp out_of_band?(:annexb) do
    false
  end

  defp out_of_band?({codec_tag, _nalu_length_size}) do
    codec_tag in [:avc1, :hvc1]
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
