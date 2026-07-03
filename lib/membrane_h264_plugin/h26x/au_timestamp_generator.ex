defmodule Membrane.H26x.AUTimestampGenerator do
  @moduledoc false

  alias Membrane.H26x.{AUSplitter, NALu}

  @type framerate :: {frames :: pos_integer(), seconds :: pos_integer()}

  @type config :: %{
          :framerate => framerate(),
          optional(:add_dts_offset) => boolean()
        }

  @type buffer_entry :: %{
          id: non_neg_integer(),
          au: AUSplitter.access_unit(),
          poc: integer(),
          dts: non_neg_integer(),
          pts: non_neg_integer() | nil
        }

  @type state :: %{
          framerate: framerate,
          max_frame_reorder: 0..15,
          au_counter: non_neg_integer(),
          pts_counter: non_neg_integer(),
          buffer_depth: non_neg_integer() | nil,
          buffer: [buffer_entry()],
          prev_pic_first_vcl_nalu: NALu.t() | nil,
          prev_pic_order_cnt_msb: integer()
        }

  @type timestamp :: non_neg_integer() | nil
  @type timestamped_au ::
          {AUSplitter.access_unit(), pts :: timestamp(), dts :: timestamp()}

  @callback max_frame_reorder() :: pos_integer()
  @callback get_first_vcl_nalu(AUSplitter.access_unit()) :: NALu.t() | nil
  @callback calculate_poc(NALu.t(), state()) :: {integer(), state()}
  @callback reorder_buffer_depth(NALu.t(), state()) :: non_neg_integer()

  defmacro __using__(_options) do
    quote location: :keep do
      @behaviour unquote(__MODULE__)

      alias Membrane.H26x.AUSplitter

      @spec new(unquote(__MODULE__).config()) :: unquote(__MODULE__).state()
      def new(config), do: unquote(__MODULE__).new(__MODULE__, config)

      @spec generate_timestamps(
              [AUSplitter.access_unit()],
              flush? :: boolean(),
              unquote(__MODULE__).state()
            ) :: {[AUSplitter.access_unit()], unquote(__MODULE__).state()}
      def generate_timestamps(access_units, flush? \\ false, state) do
        unquote(__MODULE__).generate_timestamps(__MODULE__, access_units, flush?, state)
      end
    end
  end

  @doc """
  Creates the initial state of the timestamp generator.
  """
  @spec new(module(), config()) :: state()
  def new(module, config) do
    # To make sure that PTS >= DTS at all times, we take the maximal possible
    # frame reorder and subtract `max_frame_reorder * frame_duration` from each
    # frame's DTS. This behaviour can be disabled by setting `add_dts_offset: false`.
    max_frame_reorder =
      if Map.get(config, :add_dts_offset, true), do: module.max_frame_reorder(), else: 0

    %{
      framerate: config.framerate,
      max_frame_reorder: max_frame_reorder,
      au_counter: 0,
      pts_counter: 0,
      buffer_depth: nil,
      buffer: [],
      prev_pic_first_vcl_nalu: nil,
      prev_pic_order_cnt_msb: 0
    }
  end

  @doc """
  Feeds the access units (in decode order) through the generator, returning
  those that are ready to be emitted (also in decode order) with their
  `{pts, dts}` written onto the first VCL NALu.

  If `flush?` is set to `true`, all the access units still buffered after
  feeding the input are drained and returned as well. To be done on end of
  stream or when the generator is no longer going to be used.
  """
  @spec generate_timestamps(module(), [AUSplitter.access_unit()], boolean(), state()) ::
          {[AUSplitter.access_unit()], state()}
  def generate_timestamps(module, access_units, flush? \\ false, state) do
    {ready, state} =
      Enum.flat_map_reduce(access_units, state, fn au, state ->
        put_access_unit(module, au, state)
      end)

    {drained, state} = if flush?, do: drain(state), else: {[], state}

    outputs =
      Enum.map(ready ++ drained, fn {au, pts, dts} -> put_timestamps(module, au, pts, dts) end)

    {outputs, state}
  end

  @spec put_access_unit(module(), AUSplitter.access_unit(), state()) ::
          {[timestamped_au()], state()}
  defp put_access_unit(module, au, state) do
    first_vcl_nalu = module.get_first_vcl_nalu(au)

    if first_vcl_nalu == nil or Enum.any?(au, &(&1.status != :valid)) do
      # An access unit without a valid VCL NALu has no POC to compute.
      {[{au, nil, nil}], state}
    else
      buffer_access_unit(module, au, first_vcl_nalu, state)
    end
  end

  @spec buffer_access_unit(module(), AUSplitter.access_unit(), NALu.t(), state()) ::
          {[timestamped_au()], state()}
  defp buffer_access_unit(module, au, first_vcl_nalu, state) do
    %{
      au_counter: au_counter,
      max_frame_reorder: max_frame_reorder,
      framerate: {frames, seconds}
    } = state

    {poc, state} = module.calculate_poc(first_vcl_nalu, state)
    dts = div((au_counter - max_frame_reorder) * seconds * Membrane.Time.second(), frames)

    # The POC counter rolling over to 0 means a new GOP begins, so no
    # access unit buffered so far can be reordered past this point and
    # they all can be drained.
    {flushed, state} =
      if poc == 0 and state.buffer != [], do: drain(state), else: {[], state}

    # we might need to update max_depth for a new GOP
    state =
      if poc == 0 or state.buffer_depth == nil do
        depth = module.reorder_buffer_depth(first_vcl_nalu, state)
        %{state | buffer_depth: depth}
      else
        state
      end

    entry = %{id: au_counter, au: au, poc: poc, dts: dts, pts: nil}

    state = %{state | buffer: state.buffer ++ [entry], au_counter: au_counter + 1}

    unassigned = Enum.reject(state.buffer, & &1.pts)

    excess = Enum.drop(unassigned, state.buffer_depth)

    state =
      Enum.reduce(excess, state, fn _excess_entry, acc_state ->
        assign_next_pts(acc_state)
      end)

    {ready, state} = pop_ready(state)
    {flushed ++ ready, state}
  end

  @spec put_timestamps(module(), AUSplitter.access_unit(), timestamp(), timestamp()) ::
          AUSplitter.access_unit()
  defp put_timestamps(module, au, pts, dts) do
    first_vcl_nalu = module.get_first_vcl_nalu(au)

    Enum.map(au, fn nalu ->
      if nalu == first_vcl_nalu, do: %{nalu | timestamps: {pts, dts}}, else: nalu
    end)
  end

  @spec assign_next_pts(state()) :: state()
  defp assign_next_pts(state) do
    %{framerate: {frames, seconds}, pts_counter: pts_counter, buffer: buffer} = state

    {_next, index} =
      buffer
      |> Enum.with_index()
      |> Enum.reject(fn {entry, _idx} -> entry.pts end)
      |> Enum.min_by(fn {entry, _idx} -> entry.poc end)

    pts = div(pts_counter * seconds * Membrane.Time.second(), frames)
    updated_buffer = List.update_at(buffer, index, &%{&1 | pts: pts})

    %{state | buffer: updated_buffer, pts_counter: pts_counter + 1}
  end

  @spec pop_ready(state()) :: {[timestamped_au()], state()}
  defp pop_ready(state) do
    {ready, rest} = Enum.split_while(state.buffer, &(&1.pts != nil))
    {Enum.map(ready, &{&1.au, &1.pts, &1.dts}), %{state | buffer: rest}}
  end

  @spec drain(state()) :: {[timestamped_au()], state()}
  defp drain(state) do
    state =
      state.buffer
      |> Enum.reject(& &1.pts)
      |> Enum.reduce(state, fn _unassigned_entry, acc_state ->
        assign_next_pts(acc_state)
      end)

    outputs = Enum.map(state.buffer, &{&1.au, &1.pts, &1.dts})
    {outputs, %{state | buffer: []}}
  end
end
