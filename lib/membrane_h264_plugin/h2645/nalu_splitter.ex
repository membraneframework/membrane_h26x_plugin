defmodule Membrane.H2645.NALuSplitter do
  @moduledoc """
  A module with functions responsible for splitting
  the h264 or h265 stream into the NAL units.

  The splitting is based on
  *"Annex B"* of the *"ITU-T Rec. H.264 (01/2012)"*.
  """

  alias Membrane.{H264, H265}

  @typedoc """
  A structure holding the state of the NALu splitter.
  """
  @opaque t :: %__MODULE__{
            input_stream_structure: H264.Parser.stream_structure() | H265.Parser.stream_structure(),
            unparsed_payload: binary()
          }

  @enforce_keys [:input_stream_structure]
  defstruct @enforce_keys ++ [unparsed_payload: <<>>]

  @doc """
  Returns a structure holding a NALu splitter state.

  The `input_stream_structure` determines which prefix is considered as delimiting two NALUs.
  By default, the inner `unparsed_payload` of the state is clean, but can be set to a given binary.
  """
  @spec new(Membrane.H26x.Common.Parser.stream_structure(), initial_binary :: binary()) ::
          t()
  def new(input_stream_structure \\ :annexb, initial_binary \\ <<>>) do
    %__MODULE__{
      input_stream_structure: input_stream_structure,
      unparsed_payload: initial_binary
    }
  end

  @doc """
  Splits the binary into NALus sequence.

  Takes a binary h264/h265 stream as an input
  and produces a list of binaries, where each binary is
  a complete NALu that can be passed to the `Membrane.H26x.Parser.NALuParser.parse/2`.

  If `assume_nalu_aligned` flag is set to `true`, input is assumed to form a complete set
  of NAL units and therefore all of them are returned. Otherwise, the NALu is not returned
  until another NALu starts, as it's the only way to prove that the NALu is complete.
  """
  @spec split(payload :: binary(), assume_nalu_aligned :: boolean, state :: t()) ::
          {[binary()], t()}
  def split(payload, assume_nalu_aligned \\ false, state) do
    total_payload = state.unparsed_payload <> payload

    nalus_payloads_list = get_complete_nalus_list(total_payload, state.input_stream_structure)

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

  defp get_complete_nalus_list(payload, {_avc_or_hevc, nalu_length_size})
       when byte_size(payload) < nalu_length_size do
    []
  end

  defp get_complete_nalus_list(payload, {avc_or_hevc, nalu_length_size}) do
    <<nalu_length::integer-size(nalu_length_size)-unit(8), rest::binary>> = payload

    if nalu_length > byte_size(rest) do
      []
    else
      <<nalu::binary-size(nalu_length + nalu_length_size), rest::binary>> = payload
      [nalu | get_complete_nalus_list(rest, {avc_or_hevc, nalu_length_size})]
    end
  end
end
