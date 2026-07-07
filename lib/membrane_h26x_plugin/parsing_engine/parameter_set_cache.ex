defmodule Membrane.H26x.ParsingEngine.ParameterSetCache do
  @moduledoc false

  # Tracks the parameter set NALus (VPS/SPS/PPS) of a stream, keyed by their type
  # and id. A parameter set redefined under an already used id replaces the cached
  # one, so the cache always holds only the currently active set per id, in the
  # order in which the ids first appeared.

  alias Membrane.H26x.NALu

  @parameter_set_types [:vps, :sps, :pps]

  @type t :: [NALu.t()]

  @spec new() :: t()
  def new(), do: []

  @spec put(t(), [NALu.t()]) :: t()
  def put(cache, nalus) do
    nalus
    |> Enum.filter(&(&1.type in @parameter_set_types))
    |> Enum.reduce(cache, fn new_ps, cache ->
      case Enum.find_index(cache, &(parameter_set_id(&1) == parameter_set_id(new_ps))) do
        nil -> cache ++ [new_ps]
        index -> List.replace_at(cache, index, new_ps)
      end
    end)
  end

  defp parameter_set_id(%NALu{type: type, parsed_fields: fields}) do
    case type do
      :vps -> {:vps, fields.video_parameter_set_id}
      :sps -> {:sps, fields.seq_parameter_set_id}
      :pps -> {:pps, fields.pic_parameter_set_id}
    end
  end
end
