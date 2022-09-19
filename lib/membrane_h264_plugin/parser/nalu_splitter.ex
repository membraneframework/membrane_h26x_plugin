defmodule Membrane.H264.Parser.NALuSplitter do
  @moduledoc """
  A module with functions responsible for splitting
  the h264 stream into the NAL units.

  The splitting is based on
  "Annex B" of the "ITU-T Rec. H.264 (01/2012)".
  """
  alias Membrane.H264.Parser.NALu

  @doc """
  A function which splits the binary into NALus sequence.

  A function takes a binary h264 stream as a input
  and produces a list of `NALu.t()` structures, with
  the `payload` and `prefix_length` fields set to
  the appropriate values, corresponding to, respectively,
  the binary payload of that NALu and the number of bytes
  of the Annex-B prefix of that NALu.
  """
  @spec extract_nalus(
          payload :: binary(),
          pts :: non_neg_integer() | nil,
          dts :: non_neg_integer() | nil,
          last_pts :: non_neg_integer() | nil,
          last_dts :: non_neg_integer() | nil,
          should_skip_last_nalu? :: boolean()
        ) :: [
          NALu.t()
        ]
  def extract_nalus(payload, pts, dts, last_pts, last_dts, should_skip_last_nalu?) do
    nalus =
      payload
      |> :binary.matches([<<0, 0, 0, 1>>, <<0, 0, 1>>])
      |> Enum.chunk_every(2, 1, [{byte_size(payload), nil}])
      |> then(&if should_skip_last_nalu?, do: Enum.drop(&1, -1), else: &1)
      |> Enum.map(fn [{from, prefix_len}, {to, _}] ->
        len = to - from

        %NALu{
          payload: :binary.part(payload, from, len),
          prefix_length: prefix_len,
          pts: pts,
          dts: dts,
          status: :valid
        }
      end)

    nalus
    |> List.update_at(0, fn nalu ->
      if last_pts != nil and last_dts != nil,
        do: %NALu{nalu | pts: last_pts, dts: last_dts},
        else: nalu
    end)
  end
end
