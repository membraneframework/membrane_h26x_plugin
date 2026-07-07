defmodule Membrane.H26x.ParameterSetCacheTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Membrane.H26x.{NALu, ParameterSetCache}

  defp sps(id, payload) do
    %NALu{
      type: :sps,
      parsed_fields: %{seq_parameter_set_id: id},
      stripped_prefix: <<0, 0, 0, 1>>,
      payload: payload,
      status: :valid
    }
  end

  defp pps(id, payload) do
    %NALu{
      type: :pps,
      parsed_fields: %{pic_parameter_set_id: id},
      stripped_prefix: <<0, 0, 0, 1>>,
      payload: payload,
      status: :valid
    }
  end

  describe "put/2" do
    test "redefining a parameter set under an existing id replaces the cached one" do
      cache = ParameterSetCache.put([], [pps(0, <<1>>)])
      cache = ParameterSetCache.put(cache, [pps(0, <<2>>)])

      assert [%NALu{type: :pps, payload: <<2>>}] = cache
    end

    test "a parameter set under a new id is kept alongside earlier ids" do
      cache = ParameterSetCache.put([], [pps(0, <<1>>)])
      cache = ParameterSetCache.put(cache, [pps(1, <<9>>)])

      assert [%NALu{payload: <<1>>}, %NALu{payload: <<9>>}] = cache
    end

    test "parameter sets of different types are cached separately under the same id" do
      cache = ParameterSetCache.put([], [sps(0, <<7>>), pps(0, <<1>>)])

      assert [%NALu{type: :sps, payload: <<7>>}, %NALu{type: :pps, payload: <<1>>}] = cache
    end

    test "a redefined parameter set keeps its position in the cache" do
      cache = ParameterSetCache.put([], [sps(0, <<7>>), pps(0, <<1>>)])
      cache = ParameterSetCache.put(cache, [sps(0, <<8>>)])

      assert [%NALu{type: :sps, payload: <<8>>}, %NALu{type: :pps, payload: <<1>>}] = cache
    end
  end
end
