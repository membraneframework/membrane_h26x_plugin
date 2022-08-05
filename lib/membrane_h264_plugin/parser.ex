defmodule Membrane.H264.Parser do
  @moduledoc false

  use Membrane.Filter

  require Membrane.Logger

  alias __MODULE__
  alias Membrane.{Buffer, H264}
  alias Membrane.H264.BinaryParser

  @ending_nalu_types [:end_of_seq, :end_of_stream]
  @default_last %{unprefixed_poslen: {0, 0}, prefixed_poslen: {0, 0}, type: :reserved}

  def_input_pad :input,
    demand_unit: :buffers,
    demand_mode: :auto,
    caps: :any

  def_output_pad :output,
    demand_mode: :auto,
    caps: {H264, stream_format: :byte_stream}

  def_options alignment: [
                type: :atom,
                spec: :au | :nal,
                default: :au,
                description: """
                Stream units carried by each output buffer. See `t:Membrane.H264.alignment_t`.

                Only `:au` alignment is supported at the moment.
                """
              ],
              caps: [
                default: %H264{
                  alignment: :au,
                  framerate: {0, 1},
                  height: 720,
                  nalu_in_metadata?: false,
                  profile: :high,
                  stream_format: :byte_stream,
                  width: 1280
                },
                description: """
                For development only.
                """
              ],
              sps: [
                type: :binary,
                default: <<>>,
                description: """
                Sequence Parameter Set NAL unit - if absent in the stream, should
                be provided via this option.
                """
              ],
              pps: [
                type: :binary,
                default: <<>>,
                description: """
                Picture Parameter Set NAL unit - if absent in the stream, should
                be provided via this option.
                """
              ]

  @impl true
  def handle_init(opts) do
    if opts.alignment != :au do
      raise("Invalid element options, only `:au` alignment is available")
    end

    state = %{
      caps: opts.caps,
      metadata: %{},
      partial_nalu: <<>>,
      parser_buffer: [],
      parser_state: :first,
      vcl_state: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_caps(:input, _caps, _ctx, state) do
    {{:ok, caps: {:output, state.caps}}, state}
  end

  @impl true
  def handle_process(:input, %Membrane.Buffer{} = buffer, _ctx, state) do
    payload = state.partial_nalu <> buffer.payload
    process(payload, [], state)
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, %{partial_nalu: nalu} = state) do
    process(nalu, [end_of_stream: :output], state)
  end

  defp process(payload, actions, state) do
    {new_payload, state} =
      payload
      |> Parser.NALu.parse()
      |> save_partial_nalu(payload, state)

    {_nalus, parser_buffer, parser_state, vcl_state, access_units} =
      BinaryParser.split_binary_into_access_units(
        new_payload,
        state.parser_buffer,
        state.parser_state,
        state.vcl_state
      )

    state = %{
      state
      | parser_buffer: parser_buffer,
        parser_state: parser_state,
        vcl_state: vcl_state
    }

    if access_units == [] do
      {:ok, state}
    else
      # FIXME: don't pass hardcoded empty metadata
      buffers = Enum.map(access_units, &wrap_into_buffer(&1, new_payload, state.metadata))
      new_actions = [{:buffer, {:output, buffers}} | actions]

      {{:ok, new_actions}, state}
    end
  end

  defp save_partial_nalu([], payload, state) do
    new_state = Map.update(state, :partial_nalu, <<>>, &(&1 <> payload))
    {<<>>, new_state}
  end

  defp save_partial_nalu(nalus, payload, state) do
    last_nalu_start =
      nalus
      |> List.last()
      |> Map.get(:prefixed_poslen)
      |> then(fn {start, _len} -> start end)

    payload_size = byte_size(payload)
    partial_nalu = :binary.part(payload, last_nalu_start, payload_size - last_nalu_start)
    new_payload = :binary.part(payload, 0, last_nalu_start)
    new_state = %{state | partial_nalu: partial_nalu}

    {new_payload, new_state}
  end

  defp wrap_into_buffer(access_unit, payload, metadata) do
    access_unit
    |> then(&parsed_length/1)
    |> then(fn {start, len} -> :binary.part(payload, start, len) end)
    |> then(&%Buffer{payload: &1, metadata: metadata})
  end

  defp parsed_length([]), do: {0, 0}

  defp parsed_length(parsed) do
    {start, _len} =
      parsed
      |> hd()
      |> get_in([:prefixed_poslen])

    len =
      parsed
      |> List.last()
      |> get_in([:unprefixed_poslen])
      |> then(fn {last_start, last_len} -> last_start + last_len - start end)

    {start, len}
  end
end
