defmodule Membrane.H26x.Common.ExpGolombConverter do
  @moduledoc """
  This module holds function responsible for converting
  from and to Exp-Golomb Notation.
  """

  @doc """
  Reads the appropriate number of bits from the bitstring and decodes an
  integer out of these bits.

  Returns the decoded integer and the rest of the bitstring, which wasn't
  used for decoding. By default, the decoded integer is an unsigned integer.
  If `negatives: true` is passed as an option, the decoded integer will be
  a signed integer.
  """
  @spec to_integer(bitstring(), keyword()) :: {integer(), bitstring()}
  def to_integer(binary, opts \\ [negatives: false])

  def to_integer(binary, negatives: should_support_negatives) do
    zeros_size = cut_zeros(binary)
    number_size = zeros_size + 1
    <<_zeros::size(zeros_size), number::size(number_size), rest::bitstring>> = binary
    number = number - 1

    if should_support_negatives do
      if rem(number, 2) == 0, do: {-div(number, 2), rest}, else: {div(number + 1, 2), rest}
    else
      {number, rest}
    end
  end

  @doc """
  Returns a bitstring with an Exponential Golomb representation of a integer.

  By default, the function expects the number to be a non-negative integer.
  If `negatives: true` option is set, the function can also encode negative
  numbers, but number encoded with `negatives: true` option also needs to be
  decoded with that option.
  """
  @spec to_bitstring(integer(), negatives: boolean()) :: bitstring()
  def to_bitstring(integer, opts \\ [negatives: false])

  def to_bitstring(integer, negatives: false) do
    # ceil(log(x)) can be calculated more accuratly and efficiently
    number_size = trunc(:math.floor(:math.log2(integer + 1))) + 1
    zeros_size = number_size - 1
    <<0::size(zeros_size), integer + 1::size(number_size)>>
  end

  def to_bitstring(integer, negatives: true) do
    if integer < 0,
      do: to_bitstring(-2 * integer, negatives: false),
      else: to_bitstring(2 * integer - 1, negatives: false)
  end

  defp cut_zeros(bitstring, how_many_zeros \\ 0) do
    <<x::1, rest::bitstring>> = bitstring

    case x do
      0 -> cut_zeros(rest, how_many_zeros + 1)
      1 -> how_many_zeros
    end
  end
end
