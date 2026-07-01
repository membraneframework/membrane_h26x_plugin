defmodule Membrane.H26x.Parser do
  @moduledoc false

  # This module used to hold the shared parser implementation. That logic now lives in
  # the Membrane-agnostic `Membrane.H26x.Parser.Core` (driven by the `Membrane.H264.Parser`
  # and `Membrane.H265.Parser` elements) and in the `Membrane.H26x.Parser.Utils` helpers.
  # What remains here are the codec-agnostic types shared across the plugin.

  @typedoc """
  Stream structure of the NALUs. In case it's not `:annexb` format, it contains an information
  about the size of each NALU's prefix describing their length.
  """
  @type stream_structure ::
          Membrane.H264.Parser.stream_structure() | Membrane.H265.Parser.stream_structure()

  @typedoc """
  Alignment of the NALUs carried by a single buffer.
  """
  @type alignment :: :bytestream | :nalu | :au

  @typedoc """
  Raw stream structure as described by the input stream format - either Annex B or a codec
  tag together with its decoder configuration record.
  """
  @type raw_stream_structure ::
          :annexb | {codec_tag :: atom(), decoder_configuration_record :: binary()}
end
