defmodule Membrane.H26x.ParsingEngine.ParameterSetCacheTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Membrane.H26x.NALu
  alias Membrane.H26x.ParsingEngine.ParameterSetCache

  defp nalu(type, parsed_fields, payload) do
    %NALu{
      type: type,
      parsed_fields: parsed_fields,
      stripped_prefix: <<0, 0, 0, 1>>,
      payload: payload,
      prefixed_payload: <<0, 0, 0, 1, payload::binary>>,
      status: :valid
    }
  end

  defp sps(id, payload), do: nalu(:sps, %{seq_parameter_set_id: id}, payload)
  defp pps(id, payload), do: nalu(:pps, %{pic_parameter_set_id: id}, payload)

  defp new_cache(repeat_parameter_sets \\ false, output_stream_structure \\ :annexb) do
    ParameterSetCache.new(repeat_parameter_sets, output_stream_structure)
  end

  describe "put/2" do
    test "redefining a parameter set under an existing id replaces the cached one" do
      cache = ParameterSetCache.put(new_cache(), [pps(0, <<1>>)])
      cache = ParameterSetCache.put(cache, [pps(0, <<2>>)])

      assert [%NALu{type: :pps, payload: <<2>>}] = cache.active
    end

    test "a parameter set under a new id is kept alongside earlier ids" do
      cache = ParameterSetCache.put(new_cache(), [pps(0, <<1>>)])
      cache = ParameterSetCache.put(cache, [pps(1, <<9>>)])

      assert [%NALu{payload: <<1>>}, %NALu{payload: <<9>>}] = cache.active
    end

    test "parameter sets of different types are cached separately under the same id" do
      cache = ParameterSetCache.put(new_cache(), [sps(0, <<7>>), pps(0, <<1>>)])

      assert [%NALu{type: :sps, payload: <<7>>}, %NALu{type: :pps, payload: <<1>>}] =
               cache.active
    end

    test "a redefined parameter set keeps its position in the cache" do
      cache = ParameterSetCache.put(new_cache(), [sps(0, <<7>>), pps(0, <<1>>)])
      cache = ParameterSetCache.put(cache, [sps(0, <<8>>)])

      assert [%NALu{type: :sps, payload: <<8>>}, %NALu{type: :pps, payload: <<1>>}] =
               cache.active
    end

    test "NALus other than parameter sets are ignored" do
      idr = nalu(:idr, %{}, <<5>>)
      cache = ParameterSetCache.put(new_cache(), [sps(0, <<7>>), idr])

      assert [%NALu{type: :sps, payload: <<7>>}] = cache.active
    end
  end

  describe "take/2" do
    test "returns the parameter sets put since the previous call" do
      cache = ParameterSetCache.put(new_cache(), [sps(0, <<7>>), pps(0, <<1>>)])

      assert {[%NALu{payload: <<7>>}, %NALu{payload: <<1>>}], cache} =
               ParameterSetCache.take(cache, true)

      assert {[], cache} = ParameterSetCache.take(cache, true)

      cache = ParameterSetCache.put(cache, [pps(1, <<9>>)])
      assert {[%NALu{payload: <<9>>}], _cache} = ParameterSetCache.take(cache, false)
    end

    test "returns only the latest of the parameter sets put under the same id" do
      cache = ParameterSetCache.put(new_cache(), [sps(0, <<7>>), pps(0, <<1>>), sps(0, <<8>>)])

      assert {[%NALu{payload: <<8>>}, %NALu{payload: <<1>>}], _cache} =
               ParameterSetCache.take(cache, true)
    end

    test "returns a parameter set put again unchanged" do
      cache = ParameterSetCache.put(new_cache(), [sps(0, <<7>>)])
      {_parameter_sets, cache} = ParameterSetCache.take(cache, true)
      cache = ParameterSetCache.put(cache, [sps(0, <<7>>)])

      assert {[%NALu{payload: <<7>>}], _cache} = ParameterSetCache.take(cache, true)
    end

    test "with repeating enabled returns all the active parameter sets for each keyframe" do
      cache = ParameterSetCache.put(new_cache(true), [sps(0, <<7>>), pps(0, <<1>>)])
      {_parameter_sets, cache} = ParameterSetCache.take(cache, true)

      assert {[], cache} = ParameterSetCache.take(cache, false)

      assert {[%NALu{payload: <<7>>}, %NALu{payload: <<1>>}], _cache} =
               ParameterSetCache.take(cache, true)
    end

    test "returns nothing when the output stream structure carries the parameter sets out-of-band" do
      cache = ParameterSetCache.put(new_cache(true, {:avc1, 4}), [sps(0, <<7>>), pps(0, <<1>>)])
      assert {[], _cache} = ParameterSetCache.take(cache, true)

      cache = ParameterSetCache.put(new_cache(true, {:avc3, 4}), [sps(0, <<7>>), pps(0, <<1>>)])

      assert {[%NALu{payload: <<7>>}, %NALu{payload: <<1>>}], _cache} =
               ParameterSetCache.take(cache, true)
    end
  end
end
