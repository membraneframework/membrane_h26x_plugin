defmodule Membrane.H26x.ParsingEngine.NALuParser.SchemeParserTest do
  use ExUnit.Case, async: true

  alias Membrane.H26x.ParsingEngine.NALuParser.SchemeParser

  defmodule Bytes do
    @behaviour Membrane.H26x.ParsingEngine.NALuParser.Scheme

    @impl true
    def defaults(), do: []

    @impl true
    def scheme(),
      do: [
        field: {:count, :u8},
        for: {[iterator: :i, from: 1, to: {& &1, [:count]}], field: {:byte, :u8}}
      ]
  end

  test "emulation prevention bytes straddling a chunk boundary are removed" do
    for zeros_before_boundary <- 1..2 do
      head = :binary.copy(<<0xAA>>, 63 - zeros_before_boundary)

      payload =
        <<70>> <> head <> <<0, 0, 3, 1>> <> :binary.copy(<<0xBB>>, 70 - byte_size(head) - 3)

      {:ok, %{byte: bytes}, _state} = SchemeParser.parse_with_scheme(payload, Bytes)

      assert Enum.map(1..70, &bytes[&1]) ==
               :binary.bin_to_list(
                 head <> <<0, 0, 1>> <> :binary.copy(<<0xBB>>, 70 - byte_size(head) - 3)
               )
    end
  end
end
