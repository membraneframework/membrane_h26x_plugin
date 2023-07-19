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
  @opaque t :: %__MODULE__{
            unparsed_payload: binary(),
            stream_type: :annexb | {:avcc, nalu_length_size :: pos_integer()}
          }

  @enforce_keys [:stream_type]
  defstruct @enforce_keys ++ [unparsed_payload: <<>>]

  @doc """
  Returns a structure holding a NALu splitter state.

  By default, the inner `unparsed_payload` of the state is clean.
  However, there is a possibility to set that `unparsed_payload`
  to a given binary, provided as an argument of the `new/1` function.
  """
  @spec new(:annexb | {:avcc, nalu_length_size :: pos_integer()}, initial_binary :: binary()) ::
          t()
  def new(stream_type \\ :annexb, initial_binary \\ <<>>) do
    %__MODULE__{stream_type: stream_type, unparsed_payload: initial_binary}
  end

  @doc """
  Splits the binary into NALus sequence.

  Takes a binary h264 stream as an input
  and produces a list of binaries, where each binary is
  a complete NALu that can be passed to the `Membrane.H264.Parser.NALuParser.parse/2`.
  """
  @spec split(payload :: binary(), state :: t()) ::
          {[binary()], t()}
  def split(payload, state) do
    total_payload = state.unparsed_payload <> payload

    nalus_payloads_list = get_complete_nalus_list(total_payload, state.stream_type)

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

  defp get_complete_nalus_list(payload, :annexb) do
    payload
    |> :binary.matches([<<0, 0, 0, 1>>, <<0, 0, 1>>])
    |> Enum.chunk_every(2, 1, [{byte_size(payload), nil}])
    |> then(&Enum.drop(&1, -1))
    |> Enum.map(fn [{from, _prefix_len}, {to, _}] ->
      len = to - from
      :binary.part(payload, from, len)
    end)
  end

  defp get_complete_nalus_list(payload, {:avcc, length_size}) do
    <<nalu_length::size(length_size), rest::binary>> = payload

    if nalu_length > byte_size(rest) do
      []
    else
      <<nalu::integer-size(nalu_length + length_size)-unit(8), rest::binary>> = payload
      [nalu | get_complete_nalus_list(rest, {:avcc, length_size})]
    end
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
