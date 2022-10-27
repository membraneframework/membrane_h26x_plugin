defmodule Membrane.H264.Parser.NALuSplitter do
  @moduledoc """
  A module with functions responsible for splitting
  the h264 stream into the NAL units.

  The splitting is based on
  "Annex B" of the "ITU-T Rec. H.264 (01/2012)".
  """

  @opaque t :: %__MODULE__{unparsed_payload: binary()}

  defstruct unparsed_payload: <<>>
  @spec new() :: t()
  def new(), do: %__MODULE__{}

  @doc """
  Splits the binary into NALus sequence.

  A function takes a binary h264 stream as a input
  and produces a list of binaries, where each binary is
  a complete NALu that needs to be passed to the `Membrane.H264.Parser.NALuParser.parse/2`.
  """
  @spec split(payload :: binary(), state :: t()) :: {[binary()], t()}
  def split(payload, state) do
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

    total_nalus_payloads_size = Enum.reduce(nalus_payloads_list, 0, &(byte_size(&1) + &2))

    state = %{
      state
      | unparsed_payload:
          :binary.part(
            total_payload,
            total_nalus_payloads_size,
            byte_size(total_payload) - total_nalus_payloads_size
          )
    }

    {nalus_payloads_list, state}
  end

  @doc """
  Flushes the payload out of the splitter state.

  That function gets the payload from the inner state
  of the splitter and sets the payload in the inner state
  clean.
  """
  @spec flush(t()) :: {binary(), t()}
  def flush(state) do
    {state.unparsed_payload, %{state | unparsed_payload: <<>>}}
  end
end
