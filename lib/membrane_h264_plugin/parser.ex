defmodule Membrane.H264.Parser do
  @moduledoc false

  use Membrane.Filter

  require Membrane.Logger

  alias __MODULE__
  alias Membrane.{Buffer, H264}
  alias Membrane.H264.AccessUnitSplitter

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
      nalu_state: %{__global__: %{}},
      partial_nalu: <<>>,
      buffer_payload: <<>>,
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
    process(nalu, [{:end_of_stream, :output}], state)
  end

  defp process(payload, actions, state) do
    {nalus, state} =
      payload
      |> Parser.NALu.parse(state.nalu_state)
      |> save_partial_nalu(payload, state)

    new_payload = state.buffer_payload <> payload
    new_nalus = update_parsed_poslens(nalus, &(&1 + byte_size(state.buffer_payload)))

    {access_units, state} =
      new_nalus
      |> AccessUnitSplitter.split_nalus_into_access_units(
        state.parser_buffer,
        state.parser_state,
        state.vcl_state,
        []
      )
      |> save_splitter_state(new_payload, state)

    if access_units == [] do
      {{:ok, actions}, state}
    else
      # FIXME: don't pass hardcoded empty metadata
      buffers = Enum.map(access_units, &wrap_into_buffer(&1, new_payload, state.metadata))
      new_actions = [{:buffer, {:output, buffers}} | actions]
      {{:ok, new_actions}, state}
    end
  end

  defp save_partial_nalu({[], nalu_state}, payload, state) do
    new_state =
      state
      |> Map.update(:partial_nalu, <<>>, &(&1 <> payload))
      |> Map.put(:nalu_state, nalu_state)

    {<<>>, new_state}
  end

  defp save_partial_nalu({nalus, nalu_state}, payload, state) do
    last_nalu_start =
      nalus
      |> List.last()
      |> Map.get(:prefixed_poslen)
      |> then(fn {start, _len} -> start end)

    payload_size = byte_size(payload)
    partial_nalu = :binary.part(payload, last_nalu_start, payload_size - last_nalu_start)
    new_state = %{state | partial_nalu: partial_nalu, nalu_state: nalu_state}
    new_nalus = Enum.drop(nalus, -1)

    {new_nalus, new_state}
  end

  defp save_splitter_state({_nalus, parser_buffer, parser_state, vcl_state, aus}, payload, state) do
    {buffer_start, buffer_length} = parsed_poslen(parser_buffer)

    new_parser_buffer = update_parsed_poslens(parser_buffer, &(&1 - buffer_start))
    buffer_payload = :binary.part(payload, buffer_start, buffer_length)

    state = %{
      state
      | parser_buffer: new_parser_buffer,
        buffer_payload: buffer_payload,
        parser_state: parser_state,
        vcl_state: vcl_state
    }

    {aus, state}
  end

  defp wrap_into_buffer(access_unit, payload, metadata) do
    access_unit
    |> then(&parsed_poslen/1)
    |> then(fn {start, len} -> :binary.part(payload, start, len) end)
    |> then(&%Buffer{payload: &1, metadata: metadata})
  end

  #
  defp update_parsed_poslens(parsed, fun) do
    parsed
    |> update_in([Access.all(), :prefixed_poslen], fn {start, len} -> {fun.(start), len} end)
    |> update_in([Access.all(), :unprefixed_poslen], fn {start, len} -> {fun.(start), len} end)
  end

  defp parsed_poslen([]), do: {0, 0}

  defp parsed_poslen(parsed) do
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
