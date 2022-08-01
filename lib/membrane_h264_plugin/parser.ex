defmodule Membrane.H264.Parser do
  @moduledoc false

  use Membrane.Filter

  require Membrane.Logger

  alias __MODULE__
  alias Membrane.{Buffer, H264}

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
      partial_au: {[], <<>>},
      partial_nalu: <<>>
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

    {access_units, payload, state} =
      payload
      |> Parser.NALu.parse()
      |> Enum.chunk_while([], &chunk_au_fun/2, &{:cont, Enum.reverse(&1), []})
      |> save_partial_nalu(payload, state)
      |> then(fn {aus, payload, state} -> add_partial_au(aus, payload, state) end)
      |> then(fn {aus, payload, state} -> save_partial_au(aus, payload, state) end)

    if access_units == [] do
      {:ok, state}
    else
      buffers = Enum.map(access_units, &wrap_into_buffer(&1, payload, state.metadata))

      {{:ok, buffer: {:output, buffers}}, state}
    end
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, %{partial_au: au, partial_nalu: nalu} = state) do
    {_parsed, payload} = au

    new_payload = payload <> nalu

    buffers =
      new_payload
      |> Parser.NALu.parse(true)
      |> wrap_into_buffer(new_payload, state.metadata)

    new_state =
      state
      |> Map.put(:partial_au, {[], <<>>})
      |> Map.put(:partial_nalu, <<>>)

    {{:ok, buffer: {:output, buffers}, end_of_stream: :output}, new_state}
  end

  defp chunk_au_fun(nalu, []), do: {:cont, [nalu]}

  defp chunk_au_fun(nalu, acc) do
    case nalu.type do
      :aud -> {:cont, Enum.reverse(acc), [nalu]}
      :end_of_seq -> {:cont, Enum.reverse([nalu | acc]), []}
      :end_of_stream -> {:halt, Enum.reverse([nalu | acc])}
      _type -> {:cont, [nalu | acc]}
    end
  end

  defp save_partial_nalu(access_units, payload, state) do
    payload_size = byte_size(payload)

    partial_start =
      access_units
      |> List.last([@default_last])
      |> parsed_length()
      |> then(fn {start, len} -> start + len end)

    partial_nalu = :binary.part(payload, partial_start, payload_size - partial_start)
    new_payload = :binary.part(payload, 0, partial_start)
    new_state = %{state | partial_nalu: partial_nalu}
    {access_units, new_payload, new_state}
  end

  defp add_partial_au(access_units, payload, state) do
    {au_parsed, au_payload} = state.partial_au

    size = byte_size(au_payload)
    update_size = fn {from, len} -> {from + size, len} end

    [head | tail] = Enum.map(access_units, &update_parsed_poslens(&1, update_size))

    {[au_parsed ++ head | tail], au_payload <> payload, state}
  end

  defp save_partial_au(access_units, payload, state) do
    partial_parsed = List.last(access_units, [@default_last])
    last_partial_nalu = List.last(partial_parsed, @default_last)

    if last_partial_nalu.type in @ending_nalu_types do
      {access_units, payload, %{state | partial_au: {[], <<>>}}}
    else
      {start, len} = parsed_length(partial_parsed)
      partial_payload = :binary.part(payload, start, len)

      update_start = fn {from, len} -> {from - start, len} end
      new_partial_parsed = update_parsed_poslens(partial_parsed, update_start)

      new_state = %{state | partial_au: {new_partial_parsed, partial_payload}}
      new_access_units = Enum.drop(access_units, -1)
      new_payload = :binary.part(payload, 0, start)
      {new_access_units, new_payload, new_state}
    end
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

  defp update_parsed_poslens(parsed, fun) do
    parsed
    |> update_in([Access.all(), :prefixed_poslen], fun)
    |> update_in([Access.all(), :unprefixed_poslen], fun)
  end

  defp wrap_into_buffer(access_unit, payload, metadata) do
    access_unit
    |> then(&parsed_length/1)
    |> then(fn {start, len} -> :binary.part(payload, start, len) end)
    |> then(&%Buffer{payload: &1, metadata: metadata})
  end
end
