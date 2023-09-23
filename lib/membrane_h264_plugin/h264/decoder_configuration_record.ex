defmodule Membrane.H264.DecoderConfigurationRecord do
  @moduledoc """
  Utility functions for parsing and generating AVC Configuration Record.

  The structure of the record is described in section 5.2.4.1.1 of MPEG-4 part 15 (ISO/IEC 14496-15).
  """

  alias Membrane.H264.Parser

  @enforce_keys [
    :spss,
    :ppss,
    :avc_profile_indication,
    :avc_level,
    :profile_compatibility,
    :nalu_length_size
  ]
  defstruct @enforce_keys

  @typedoc "Structure representing the Decoder Configuartion Record"
  @type t() :: %__MODULE__{
          spss: [binary()],
          ppss: [binary()],
          avc_profile_indication: non_neg_integer(),
          profile_compatibility: non_neg_integer(),
          avc_level: non_neg_integer(),
          nalu_length_size: pos_integer()
        }

  @doc """
  Generates a DCR based on given PPSs and SPSs.
  """
  @spec generate([binary()], [binary()], Parser.stream_structure()) ::
          binary() | nil
  def generate([], _ppss, _stream_structure) do
    nil
  end

  def generate(spss, ppss, {avc, nalu_length_size}) do
    <<_idc_and_type, profile, compatibility, level, _rest::binary>> = List.last(spss)

    cond do
      avc == :avc1 ->
        <<1, profile, compatibility, level, 0b111111::6, nalu_length_size - 1::2-integer,
          0b111::3, length(spss)::5-integer, encode_parameter_sets(spss)::binary,
          length(ppss)::8-integer, encode_parameter_sets(ppss)::binary>>

      avc == :avc3 ->
        <<1, profile, compatibility, level, 0b111111::6, nalu_length_size - 1::2-integer,
          0b111::3, 0::5, 0::8>>
    end
  end

  defp encode_parameter_sets(pss) do
    Enum.map_join(pss, &<<byte_size(&1)::16-integer, &1::binary>>)
  end

  @spec remove_parameter_sets(binary()) :: binary()
  def remove_parameter_sets(dcr) do
    <<dcr_head::binary-(8 * 5), _rest::binary>> = dcr
    <<dcr_head::binary, 0b111::3, 0::5, 0::8>>
  end

  @doc """
  Parses the DCR.
  """
  @spec parse(binary()) :: t()
  def parse(
        <<1::8, avc_profile_indication::8, profile_compatibility::8, avc_level::8, 0b111111::6,
          length_size_minus_one::2, 0b111::3, rest::bitstring>>
      ) do
    {spss, rest} = parse_spss(rest)
    {ppss, _rest} = parse_ppss(rest)

    %__MODULE__{
      spss: spss,
      ppss: ppss,
      avc_profile_indication: avc_profile_indication,
      profile_compatibility: profile_compatibility,
      avc_level: avc_level,
      nalu_length_size: length_size_minus_one + 1
    }
  end

  def parse(_data), do: {:error, :unknown_pattern}

  defp parse_spss(<<num_of_spss::5, rest::bitstring>>) do
    do_parse_array(num_of_spss, rest)
  end

  defp parse_ppss(<<num_of_ppss::8, rest::bitstring>>), do: do_parse_array(num_of_ppss, rest)

  defp do_parse_array(amount, rest, acc \\ [])
  defp do_parse_array(0, rest, acc), do: {Enum.reverse(acc), rest}

  defp do_parse_array(remaining, <<size::16, data::binary-size(size), rest::bitstring>>, acc),
    do: do_parse_array(remaining - 1, rest, [data | acc])
end
