defmodule ExpGolombTest do
  @moduledoc false

  use ExUnit.Case, async: true
  alias Membrane.H26x.ExpGolombConverter
  @integers [0, 1, -3, 5, 12, 51, -13_413, 25_542, 2137]

  test "if the decoding the encoded integer results in the original integer" do
    for integer <- @integers do
      negatives = integer < 0

      assert integer ==
               integer
               |> ExpGolombConverter.to_bitstring(negatives: negatives)
               |> ExpGolombConverter.to_integer(negatives: negatives)
               |> elem(0)
    end
  end
end
