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
            input_stream_structure: Membrane.H264.Parser.stream_structure(),
            unparsed_payload: binary()
          }

  @enforce_keys [:input_stream_structure]
  defstruct @enforce_keys ++ [unparsed_payload: <<>>]

  @doc """
  Returns a structure holding a NALu splitter state.

  By default, the inner `unparsed_payload` of the state is clean.
  However, there is a possibility to set that `unparsed_payload`
  to a given binary, provided as an argument of the `new/1` function.
  """
  @spec new(Membrane.H264.Parser.stream_structure(), initial_binary :: binary()) ::
          t()
  def new(input_stream_structure \\ :annexb, initial_binary \\ <<>>) do
    %__MODULE__{
      input_stream_structure: input_stream_structure,
      unparsed_payload: initial_binary
    }
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

    nalus_payloads_list = get_complete_nalus_list(total_payload, state.input_stream_structure)

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

  defp get_complete_nalus_list(payload, {_avc, nalu_length_size})
       when byte_size(payload) < nalu_length_size do
    []
  end

  defp get_complete_nalus_list(payload, {_avc, nalu_length_size}) do
    <<nalu_length::integer-size(nalu_length_size)-unit(8), rest::binary>> = payload

    if nalu_length > byte_size(rest) do
      []
    else
      <<nalu::binary-size(nalu_length + nalu_length_size), rest::binary>> = payload
      [nalu | get_complete_nalus_list(rest, {:avcc, nalu_length_size})]
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
