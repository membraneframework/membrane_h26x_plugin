defmodule Membrane.H265.DecoderConfigurationRecord do
  @moduledoc """
  Utility functions for parsing and generating HEVC Configuration Record.

  The structure of the record is described in section 8.3.3.1.1 of MPEG-4 part 15 (ISO/IEC 14496-15 Edition 2017-02).
  """

  alias Membrane.H26x.NALu

  @enforce_keys [
    :vpss,
    :spss,
    :ppss,
    :profile_space,
    :tier_flag,
    :profile_idc,
    :profile_compatibility_flags,
    :constraint_indicator_flags,
    :level_idc,
    :temporal_id_nested,
    :num_temporal_layers,
    :chroma_format_idc,
    :bit_depth_luma_minus8,
    :bit_depth_chroma_minus8,
    :nalu_length_size
  ]
  defstruct @enforce_keys

  @typedoc "Structure representing the Decoder Configuartion Record"
  @type t() :: %__MODULE__{
          vpss: [binary()],
          spss: [binary()],
          ppss: [binary()],
          profile_space: non_neg_integer(),
          tier_flag: non_neg_integer(),
          profile_idc: non_neg_integer(),
          profile_compatibility_flags: non_neg_integer(),
          constraint_indicator_flags: non_neg_integer(),
          level_idc: non_neg_integer(),
          chroma_format_idc: non_neg_integer(),
          bit_depth_luma_minus8: non_neg_integer(),
          bit_depth_chroma_minus8: non_neg_integer(),
          temporal_id_nested: non_neg_integer(),
          num_temporal_layers: non_neg_integer(),
          nalu_length_size: non_neg_integer()
        }

  @doc """
  Generates a DCR based on given PPSs, SPSs and VPSs.
  """
  @spec generate([NALu.t()], [NALu.t()], [NALu.t()], Membrane.H265.Parser.stream_structure()) ::
          binary() | nil
  def generate(_vpss, [], _ppss, _stream_structure) do
    nil
  end

  def generate(vpss, spss, ppss, {avc, nalu_length_size}) do
    %NALu{
      parsed_fields: %{
        profile_space: profile_space,
        tier_flag: tier_flag,
        profile_idc: profile_idc,
        profile_compatibility_flag: profile_compatibility_flag,
        progressive_source_flag: progressive_source_flag,
        interlaced_source_flag: interlaced_source_flag,
        non_packed_constraint_flag: non_packed_constraint_flag,
        frame_only_constraint_flag: frame_only_constraint_flag,
        reserved_zero_44bits: reserved_zero_44bits,
        level_idc: level_idc,
        chroma_format_idc: chroma_format_idc,
        bit_depth_luma_minus8: bit_depth_luma_minus8,
        bit_depth_chroma_minus8: bit_depth_chroma_minus8,
        temporal_id_nesting_flag: temporal_id_nested,
        max_sub_layers_minus1: num_temporal_layers
      }
    } = List.last(spss)

    common_config =
      <<1, profile_space::2, tier_flag::1, profile_idc::5, profile_compatibility_flag::32,
        progressive_source_flag::1, interlaced_source_flag::1, non_packed_constraint_flag::1,
        frame_only_constraint_flag::1, reserved_zero_44bits::44, level_idc, 0b1111::4,
        _min_spatial_segmentation_idc = 0::12, 0b111111::6, _parallelism_type = 0::2, 0b111111::6,
        chroma_format_idc::2, 0b11111::5, bit_depth_luma_minus8::3, 0b11111::5,
        bit_depth_chroma_minus8::3, _average_framerate = 0::16, _constant_framerate = 0::2,
        num_temporal_layers + 1::3, temporal_id_nested::1, nalu_length_size - 1::2-integer>>

    cond do
      avc == :hvc1 ->
        <<common_config::binary, 3::8, encode_parameter_sets(vpss, 32)::binary,
          encode_parameter_sets(spss, 33)::binary, encode_parameter_sets(ppss, 34)::binary>>

      avc == :hev1 ->
        <<common_config::binary, 0::8>>
    end
  end

  defp encode_parameter_sets(pss, nalu_type) do
    <<2::2, nalu_type::6, length(pss)::16>> <>
      Enum.map_join(pss, &<<byte_size(&1.payload)::16-integer, &1.payload::binary>>)
  end

  @doc """
  Parses the DCR.
  """
  @spec parse(binary()) :: t()
  def parse(
        <<1::8, profile_space::2, tier_flag::1, profile_idc::5, profile_compatibility_flags::32,
          constraint_indicator_flags::48, level_idc::8, 0b1111::4,
          _min_spatial_segmentation_idc::12, 0b111111::6, _parallelism_type::2, 0b111111::6,
          chroma_format_idc::2, 0b11111::5, bit_depth_luma_minus8::3, 0b11111::5,
          bit_depth_chroma_minus8::3, _avg_frame_rate::16, _constant_frame_rate::2,
          num_temporal_layers::3, temporal_id_nested::1, length_size_minus_one::2-integer,
          num_of_arrays::8, rest::bitstring>>
      ) do
    {vpss, spss, ppss} =
      if num_of_arrays > 0 do
        {vpss, rest} = parse_pss(rest, 32)
        {spss, rest} = parse_pss(rest, 33)
        {ppss, _rest} = parse_pss(rest, 34)

        {vpss, spss, ppss}
      else
        {[], [], []}
      end

    %__MODULE__{
      vpss: vpss,
      spss: spss,
      ppss: ppss,
      profile_space: profile_space,
      tier_flag: tier_flag,
      profile_idc: profile_idc,
      profile_compatibility_flags: profile_compatibility_flags,
      constraint_indicator_flags: constraint_indicator_flags,
      level_idc: level_idc,
      temporal_id_nested: temporal_id_nested,
      num_temporal_layers: num_temporal_layers,
      chroma_format_idc: chroma_format_idc,
      bit_depth_luma_minus8: bit_depth_luma_minus8,
      bit_depth_chroma_minus8: bit_depth_chroma_minus8,
      nalu_length_size: length_size_minus_one + 1
    }
  end

  def parse(_data), do: {:error, :unknown_pattern}

  defp parse_pss(<<_reserved::2, type::6, num_of_pss::16, rest::bitstring>>, type) do
    do_parse_array(num_of_pss, rest)
  end

  defp do_parse_array(amount, rest, acc \\ [])
  defp do_parse_array(0, rest, acc), do: {Enum.reverse(acc), rest}

  defp do_parse_array(remaining, <<size::16, data::binary-size(size), rest::bitstring>>, acc),
    do: do_parse_array(remaining - 1, rest, [data | acc])
end
