defmodule Membrane.H264.Parser.NALuSplitter do
  @moduledoc """
  A module with functions responsible for splitting
  the h264 stream into the NAL units.

  The splitting is based on
  *"Annex B"* of the *"ITU-T Rec. H.264 (01/2012)"*.
  """

  @typedoc """
  A structure holding the state of the NALu splitter.
  """
  @opaque t :: %__MODULE__{unparsed_payload: binary()}

  defstruct unparsed_payload: <<>>

  @doc """
  Returns a structure holding a NALu splitter state.

  By default, the inner `unparsed_payload` of the state is clean.
  However, there is a possibility to set that `unparsed_payload`
  to a given binary, provided as an argument of the `new/1` function.
  """
  @spec new(binary()) :: t()
  def new(intial_binary \\ <<>>) do
    %__MODULE__{unparsed_payload: intial_binary}
  end

  @doc """
  Splits the binary into NALus sequence.

  Takes a binary h264 stream as an input
  and produces a list of binaries, where each binary is
  a complete NALu that can be passed to the `Membrane.H264.Parser.NALuParser.parse/2`.

  If `assume_nalu_aligned` flag is set to `true`, input is assumed to form a complete set
  of NAL units and therefore all of them are returned. Otherwise, the NALu is not returned
  until another NALu starts, as it's the only way to prove that the NALu is complete.
  """
  @spec split(payload :: binary(), assume_nalu_aligned :: boolean, state :: t()) ::
          {[binary()], t()}
  def split(payload, assume_nalu_aligned \\ false, state) do
    total_payload = state.unparsed_payload <> payload

    nalus_payloads_list =
      total_payload
      |> :binary.matches([<<0, 0, 0, 1>>, <<0, 0, 1>>])
      |> Enum.chunk_every(2, 1, [{byte_size(payload), nil}])
      |> then(&Enum.drop(&1, -1))
      |> Enum.map(fn [{from, _prefix_len}, {to, _}] ->
        len = to - from
        :binary.part(total_payload, from, len)
      end)

    total_nalus_payloads_size = IO.iodata_length(nalus_payloads_list)

    unparsed_payload =
      :binary.part(
        total_payload,
        total_nalus_payloads_size,
        byte_size(total_payload) - total_nalus_payloads_size
      )

    cond do
      unparsed_payload == <<>> ->
        {nalus_payloads_list, %{state | unparsed_payload: <<>>}}

      assume_nalu_aligned ->
        {nalus_payloads_list ++ [unparsed_payload], %{state | unparsed_payload: <<>>}}

      true ->
        {nalus_payloads_list, %{state | unparsed_payload: unparsed_payload}}
    end
  end
end
