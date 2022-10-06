defmodule Membrane.H264.Parser.NALuParser do
  @moduledoc """
  A module providing functionality of parsing a stream of packets, out of which each
  holds a payload of a single NAL unit.

  As a result the parser outputs a stream of parsed NAL units.
  """
  alias Membrane.H264.Parser.{NALu, NALuSplitter, NALuTypes, SchemeParser}
  alias Membrane.H264.Parser.SchemeParser.Schemes

  @typedoc """
  A structure holding the state of the NALu parser.
  """
  @opaque t :: %__MODULE__{
            scheme_parser_state: SchemeParser.t(),
            has_seen_keyframe?: boolean(),
            prev_pts: non_neg_integer() | nil,
            prev_dts: non_neg_integer() | nil
          }
  @enforce_keys [:scheme_parser_state, :has_seen_keyframe?, :prev_pts, :prev_dts]
  defstruct @enforce_keys

  @doc """
  Returns an structure holding a NALu parser state.
  """
  @spec new() :: t()
  def new(),
    do: %__MODULE__{
      scheme_parser_state: SchemeParser.new(),
      has_seen_keyframe?: false,
      prev_pts: nil,
      prev_dts: nil
    }

  @doc """
  Parses a `Membrane.Buffer.t()` with a payload being a part of H264 stream.

  As a result it returns a list of NAL units, along with a part of a payload
  that wasn't completly parsed and the updated state of the NALu parser. If the
  `should_skip_last_nalu?` option is set to `false`, the last NALu in the list might
  not be complete, as it might be produced only out of a part of that NALu's binary.
  """
  @spec parse(Membrane.Buffer.t(), t(), boolean()) :: {[NALu.t()], binary(), t()}
  def parse(
        buffer,
        state,
        should_skip_last_nalu? \\ true
      ) do
    payload = buffer.payload

    {nalus, {scheme_parser_state, has_seen_keyframe?}} =
      payload
      |> NALuSplitter.extract_nalus(
        buffer.pts,
        buffer.dts,
        state.prev_pts,
        state.prev_dts,
        should_skip_last_nalu?
      )
      |> Enum.map_reduce(
        {state.scheme_parser_state, state.has_seen_keyframe?},
        fn nalu, {scheme_parser_state, has_seen_keyframe?} ->
          prefix_length = nalu.prefix_length

          <<_prefix::binary-size(prefix_length), nalu_header::binary-size(1), nalu_body::binary>> =
            nalu.payload

          new_scheme_parser_state = SchemeParser.new(scheme_parser_state)

          {parsed_fields, scheme_parser_state} =
            SchemeParser.parse_with_scheme(
              nalu_header,
              Schemes.NALuHeader.scheme(),
              new_scheme_parser_state
            )

          type = NALuTypes.get_type(parsed_fields.nal_unit_type)

          try do
            {parsed_fields, scheme_parser_state} =
              parse_proper_nalu_type(nalu_body, scheme_parser_state, type)

            status = if type != :non_idr or has_seen_keyframe?, do: :valid, else: :error
            has_seen_keyframe? = has_seen_keyframe? or type == :idr

            {%NALu{nalu | parsed_fields: parsed_fields, type: type, status: status},
             {scheme_parser_state, has_seen_keyframe?}}
          catch
            "Cannot load information from SPS" ->
              {%NALu{nalu | parsed_fields: parsed_fields, type: type, status: :error},
               {scheme_parser_state, has_seen_keyframe?}}
          end
        end
      )

    state = %__MODULE__{
      scheme_parser_state: scheme_parser_state,
      has_seen_keyframe?: has_seen_keyframe?,
      prev_pts: buffer.pts,
      prev_dts: buffer.dts
    }

    unparsed_payload_start =
      nalus |> Enum.reduce(0, fn nalu, acc -> acc + byte_size(nalu.payload) end)

    unparsed_payload =
      :binary.part(payload, unparsed_payload_start, byte_size(payload) - unparsed_payload_start)

    {nalus, unparsed_payload, state}
  end

  defp parse_proper_nalu_type(payload, state, type) do
    case type do
      :sps ->
        SchemeParser.parse_with_scheme(payload, Schemes.SPS.scheme(), state)

      :pps ->
        SchemeParser.parse_with_scheme(payload, Schemes.PPS.scheme(), state)

      :idr ->
        SchemeParser.parse_with_scheme(payload, Schemes.Slice.scheme(), state)

      :non_idr ->
        SchemeParser.parse_with_scheme(payload, Schemes.Slice.scheme(), state)

      _unknown_nalu_type ->
        {%{}, state}
    end
  end
end
