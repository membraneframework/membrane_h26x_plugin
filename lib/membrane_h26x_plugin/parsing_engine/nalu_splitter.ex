defmodule Membrane.H26x.ParsingEngine.NALuSplitter do
  @moduledoc false
  # A module with functions responsible for splitting the H26x streams into the NAL units.

  alias Membrane.H26x.{ParsingEngine, Utils}

  @typedoc """
  A structure holding the state of the NALu splitter.
  """
  @type t :: %__MODULE__{
          input_stream_structure: ParsingEngine.stream_structure(),
          unparsed_payload: binary()
        }

  @enforce_keys [:input_stream_structure]
  defstruct @enforce_keys ++ [unparsed_payload: <<>>]

  @doc """
  Returns a structure holding a NALu splitter state.

  The `input_stream_structure` determines which prefix is considered as delimiting two NALUs.
  By default, the inner `unparsed_payload` of the state is clean, but can be set to a given binary.
  """
  @spec new(ParsingEngine.stream_structure(), initial_binary :: binary()) :: t()
  def new(input_stream_structure \\ :annexb, initial_binary \\ <<>>) do
    %__MODULE__{
      input_stream_structure: input_stream_structure,
      unparsed_payload: initial_binary
    }
  end

  @doc """
  Splits the binary into NALus sequence.

  Takes a binary H264 stream as an input
  and produces a list of binaries, where each binary is
  a complete NALu that can be passed to the NALu parser.

  If `assume_nalu_aligned` flag is set to `true`, input is assumed to form a complete set
  of NAL units and therefore all of them are returned. Otherwise, the NALu is not returned
  until another NALu starts, as it's the only way to prove that the NALu is complete.
  """
  @spec split(payload :: binary(), assume_nalu_aligned :: boolean, state :: t()) ::
          {[binary()], t()}
  def split(payload, assume_nalu_aligned \\ false, state) do
    {nalus_acc, remainder} =
      split_payload(
        Utils.prepend_payload(state.unparsed_payload, payload),
        byte_size(state.unparsed_payload),
        state.input_stream_structure
      )

    cond do
      remainder == <<>> ->
        {Enum.reverse(nalus_acc), %{state | unparsed_payload: <<>>}}

      assume_nalu_aligned ->
        {Enum.reverse([remainder | nalus_acc]), %{state | unparsed_payload: <<>>}}

      true ->
        {Enum.reverse(nalus_acc), %{state | unparsed_payload: remainder}}
    end
  end

  @spec split_payload(binary(), non_neg_integer(), ParsingEngine.stream_structure()) ::
          {[binary()], binary()}
  defp split_payload(payload, scanned_bytes, :annexb) do
    case find_start_code(payload, 0) do
      nil ->
        {[], payload}

      {nalu_start, search_from} ->
        # the scanned part may end with up to 3 bytes of a start code
        search_from = max(search_from, scanned_bytes - 3)
        split_annexb(payload, nalu_start, search_from, [])
    end
  end

  defp split_payload(payload, _scanned_bytes, {_codec_tag, nalu_length_size}) do
    split_length_prefixed(payload, nalu_length_size, [])
  end

  defp split_annexb(payload, nalu_start, search_from, acc) do
    case find_start_code(payload, search_from) do
      nil ->
        <<_scanned::binary-size(^nalu_start), rest::binary>> = payload
        {acc, rest}

      {next_nalu_start, search_from} ->
        nalu_size = next_nalu_start - nalu_start

        <<_scanned::binary-size(^nalu_start), nalu::binary-size(^nalu_size), _rest::binary>> =
          payload

        split_annexb(payload, next_nalu_start, search_from, [nalu | acc])
    end
  end

  # searching for a single zero byte is much faster than for the whole start code
  @spec find_start_code(binary(), non_neg_integer()) ::
          {non_neg_integer(), non_neg_integer()} | nil
  defp find_start_code(payload, from) when from + 3 > byte_size(payload), do: nil

  defp find_start_code(payload, from) do
    case :binary.match(payload, <<0>>, scope: {from, byte_size(payload) - from}) do
      :nomatch -> nil
      {position, 1} -> start_code_at(payload, position)
    end
  end

  defp start_code_at(payload, position) do
    case payload do
      <<_skip::binary-size(^position), 0, 0, 0, 1, _rest::binary>> -> {position, position + 4}
      <<_skip::binary-size(^position), 0, 0, 1, _rest::binary>> -> {position, position + 3}
      _no_start_code -> find_start_code(payload, position + 1)
    end
  end

  defp split_length_prefixed(payload, nalu_length_size, acc) do
    case payload do
      <<nalu_length::integer-size(^nalu_length_size)-unit(8), rest::binary>>
      when byte_size(rest) >= nalu_length ->
        <<nalu::binary-size(^nalu_length + ^nalu_length_size), rest::binary>> = payload
        split_length_prefixed(rest, nalu_length_size, [nalu | acc])

      _incomplete ->
        {acc, payload}
    end
  end
end
