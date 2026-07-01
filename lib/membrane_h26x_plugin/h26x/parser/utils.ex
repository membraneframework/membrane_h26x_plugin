defmodule Membrane.H26x.Parser.Utils do
  @moduledoc false

  # Membrane-coupled, but codec-agnostic, helpers shared by the `Membrane.H264.Parser`
  # and `Membrane.H265.Parser` elements.
  #
  # Unlike `Membrane.H26x.Parser.Core`, these functions know about `Membrane.Buffer`s,
  # buffer metadata and element actions - but they contain no codec-specific logic and
  # take everything they need as explicit arguments (there is no callback dispatch back
  # into the elements).

  alias Membrane.Buffer
  alias Membrane.H26x.{AUSplitter, NALuParser}
  alias Membrane.H26x.Parser.Core

  @doc """
  Decides whether the given access unit should be forwarded downstream.

  An access unit is dropped when it contains an invalid NALu, when it has no VCL NALu,
  or when we are still skipping until the first keyframe. Returns the decision together
  with the (possibly updated) `skip_until_keyframe?` flag.
  """
  @spec should_forward_au(AUSplitter.access_unit(), boolean(), boolean(), module()) ::
          {boolean(), skip_until_keyframe? :: boolean()}
  def should_forward_au(au, keyframe?, skip_until_keyframe?, nalu_parser_mod) do
    with true <- Enum.all?(au, &(&1.status == :valid)),
         true <- nalu_parser_mod.get_first_vcl_nalu(au) != nil do
      skip_until_keyframe? = skip_until_keyframe? and not keyframe?
      {not skip_until_keyframe?, skip_until_keyframe?}
    else
      false -> {false, skip_until_keyframe?}
    end
  end

  @doc """
  Wraps an access unit into a buffer (for `:au` output alignment) or a list of buffers
  (for `:nalu` output alignment), prefixing each NALu according to the output stream
  structure and attaching the metadata under the given key.
  """
  @spec wrap_into_buffer(
          AUSplitter.access_unit(),
          Membrane.Time.t(),
          Membrane.Time.t(),
          boolean(),
          :au | :nalu,
          Core.stream_structure(),
          atom()
        ) :: Buffer.t() | [Buffer.t()]
  def wrap_into_buffer(au, pts, dts, keyframe?, :au, output_stream_structure, metadata_key) do
    payload =
      Enum.reduce(au, <<>>, fn nalu, acc ->
        acc <> NALuParser.get_prefixed_nalu_payload(nalu, output_stream_structure)
      end)

    %Buffer{
      payload: payload,
      metadata: prepare_au_metadata(au, keyframe?, metadata_key),
      pts: pts,
      dts: dts
    }
  end

  def wrap_into_buffer(au, pts, dts, keyframe?, :nalu, output_stream_structure, metadata_key) do
    au
    |> Enum.zip(prepare_nalus_metadata(au, keyframe?, metadata_key))
    |> Enum.map(fn {nalu, metadata} ->
      %Buffer{
        payload: NALuParser.get_prefixed_nalu_payload(nalu, output_stream_structure),
        metadata: metadata,
        pts: pts,
        dts: dts
      }
    end)
  end

  @doc """
  Tells whether a stream format has been sent - either previously (present in `ctx`) or
  as one of the given actions.
  """
  @spec stream_format_sent?([Membrane.Element.Action.t()], map()) :: boolean()
  def stream_format_sent?(actions, %{pads: %{output: %{stream_format: nil}}}),
    do: Enum.any?(actions, &match?({:stream_format, _stream_format}, &1))

  def stream_format_sent?(_actions, _ctx), do: true

  @spec prepare_au_metadata(AUSplitter.access_unit(), boolean(), atom()) :: Buffer.metadata()
  defp prepare_au_metadata(nalus, keyframe?, metadata_key) do
    nalus =
      nalus
      |> Enum.with_index()
      |> Enum.map(fn {nalu, i} ->
        %{metadata: Map.put(%{}, metadata_key, %{type: nalu.type})}
        |> Bunch.then_if(
          i == 0,
          &put_in(&1, [:metadata, metadata_key, :new_access_unit], %{key_frame?: keyframe?})
        )
        |> Bunch.then_if(
          i == length(nalus) - 1,
          &put_in(&1, [:metadata, metadata_key, :end_access_unit], true)
        )
      end)

    %{metadata_key => %{key_frame?: keyframe?, nalus: nalus}}
  end

  @spec prepare_nalus_metadata(AUSplitter.access_unit(), boolean(), atom()) :: [Buffer.metadata()]
  defp prepare_nalus_metadata(nalus, keyframe?, metadata_key) do
    nalus
    |> Enum.with_index()
    |> Enum.map(fn {nalu, i} ->
      Map.put(%{}, metadata_key, %{type: nalu.type})
      |> Bunch.then_if(
        i == 0,
        &put_in(&1, [metadata_key, :new_access_unit], %{key_frame?: keyframe?})
      )
      |> Bunch.then_if(
        i == length(nalus) - 1,
        &put_in(&1, [metadata_key, :end_access_unit], true)
      )
    end)
  end
end
