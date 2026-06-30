defmodule Membrane.H26x.AUTimestampGenerator do
  @moduledoc false

  # The fourth "pillar" of the parser pipeline (after the NALu splitter, NALu
  # parser and AU splitter). When `generate_best_effort_timestamps` is set, the
  # access units coming out of the AU splitter are fed through this module which
  # generates their PTS and DTS based on a given framerate.
  #
  # PTS are derived from each frame's presentation order, recovered by sorting the
  # access units by their Picture Order Count (POC) - the presentation rank, not
  # the raw POC value, decides the PTS, so the result is correct regardless of the
  # step by which POC advances. To recover that order a bounded window of access
  # units is buffered (reordered) before being emitted, which introduces a small,
  # constant latency.
  #
  # The generated `{pts, dts}` are written onto each access unit's first VCL NALu
  # `:timestamps` field, so the rest of the parser reads them exactly the same way
  # it reads timestamps in the NALu/AU-aligned modes.
  #
  # The buffering/ranking logic lives entirely in this module; the codec-specific
  # parts (locating the first VCL NALu, computing the POC and the reorder depth)
  # are provided by the codec modules through the callbacks below. `use`-ing this
  # module only injects thin wrappers delegating to the functions here.

  alias Membrane.H26x.{AUSplitter, NALu}

  @type framerate :: {frames :: pos_integer(), seconds :: pos_integer()}

  @type config :: %{
          :framerate => framerate(),
          optional(:add_dts_offset) => boolean()
        }

  @typedoc """
  A single access unit buffered while waiting for its presentation order (and
  thus its PTS) to be determined.
  """
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

  @type timestamps :: {pts :: non_neg_integer(), dts :: non_neg_integer()}

  @doc """
  Returns the maximal frame reorder allowed by the codec's specification. It
  bounds both the DTS offset and the depth of the reorder buffer.
  """
  @callback max_frame_reorder() :: pos_integer()

  @callback get_first_vcl_nalu(AUSplitter.access_unit()) :: NALu.t() | nil
  @callback calculate_poc(NALu.t(), state()) :: {integer(), state()}

  @doc """
  Returns the depth of the reorder buffer (the maximal number of access units
  that may need to be buffered to recover the presentation order), based on the
  first VCL NALu of a coded video sequence.

  Returning `0` means the stream is known not to reorder frames, so no buffering
  is performed and no latency is introduced.
  """
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

  An access unit is held back until enough following access units have been
  seen to determine its presentation order.

  If `flush?` is set to `true`, all the access units still buffered after
  feeding the input are drained and returned as well. To be done on end of
  stream or when the generator is no longer going to be used.

  `module` is the codec module implementing the callbacks of this behaviour.
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
      Enum.map(ready ++ drained, fn {au, timestamps} -> put_timestamps(module, au, timestamps) end)

    {outputs, state}
  end

  # Pushes a single access unit into the reorder buffer and returns the access
  # units (paired with their `{pts, dts}`) that became ready to emit.
  @spec put_access_unit(module(), AUSplitter.access_unit(), state()) ::
          {[{AUSplitter.access_unit(), timestamps()}], state()}
  defp put_access_unit(module, au, state) do
    first_vcl_nalu = module.get_first_vcl_nalu(au)

    if first_vcl_nalu == nil or Enum.any?(au, &(&1.status != :valid)) do
      # An access unit without a valid VCL NALu has no POC to compute. It's
      # dropped further down the pipeline anyway, so it's passed through as is.
      {[{au, {nil, nil}}], state}
    else
      buffer_access_unit(module, au, first_vcl_nalu, state)
    end
  end

  defp buffer_access_unit(module, au, first_vcl_nalu, state) do
    %{
      au_counter: au_counter,
      max_frame_reorder: max_frame_reorder,
      framerate: {frames, seconds}
    } = state

    {poc, state} = module.calculate_poc(first_vcl_nalu, state)
    dts = div((au_counter - max_frame_reorder) * seconds * Membrane.Time.second(), frames)

    # A POC equal to 0 marks the beginning of a new coded video sequence whose
    # POCs restart from 0, so the previous sequence's buffer must be drained
    # first, otherwise the new low POCs would sort against the old high POCs.
    {flushed, state} =
      if poc == 0 and state.buffer != [], do: drain(state), else: {[], state}

    # The reorder depth is read from the (possibly new) SPS at the start of each
    # coded video sequence. It's clamped to the maximal reorder so it never
    # exceeds the DTS offset window (which keeps PTS >= DTS when the offset is on).
    state =
      if poc == 0 or state.buffer_depth == nil do
        depth =
          min(module.reorder_buffer_depth(first_vcl_nalu, state), module.max_frame_reorder())

        %{state | buffer_depth: depth}
      else
        state
      end

    entry = %{id: au_counter, au: au, poc: poc, dts: dts, pts: nil}

    state =
      %{state | buffer: state.buffer ++ [entry], au_counter: au_counter + 1}
      |> assign_pts_while_full()

    {ready, state} = pop_ready(state)
    {flushed ++ ready, state}
  end

  # Writes the timestamps onto the access unit's first VCL NALu.
  defp put_timestamps(module, au, timestamps) do
    first_vcl_nalu = module.get_first_vcl_nalu(au)

    Enum.map(au, fn nalu ->
      if nalu == first_vcl_nalu, do: %{nalu | timestamps: timestamps}, else: nalu
    end)
  end

  # Assigns PTS to the buffered access unit with the smallest POC as long as
  # there are more unassigned access units than the reorder buffer can hold.
  defp assign_pts_while_full(state) do
    unassigned = Enum.count(state.buffer, &(&1.pts == nil))

    if unassigned > state.buffer_depth,
      do: state |> assign_next_pts() |> assign_pts_while_full(),
      else: state
  end

  # Assigns the next presentation timestamp to the unassigned access unit with
  # the smallest POC - i.e. the next one in presentation order.
  defp assign_next_pts(state) do
    %{framerate: {frames, seconds}, pts_counter: pts_counter} = state

    next = state.buffer |> Enum.filter(&(&1.pts == nil)) |> Enum.min_by(& &1.poc)
    pts = div(pts_counter * seconds * Membrane.Time.second(), frames)

    buffer =
      Enum.map(state.buffer, fn entry ->
        if entry.id == next.id, do: %{entry | pts: pts}, else: entry
      end)

    %{state | buffer: buffer, pts_counter: pts_counter + 1}
  end

  # Pops, in decode order, the access units from the front of the buffer that
  # already have a PTS assigned.
  defp pop_ready(state) do
    {ready, rest} = Enum.split_while(state.buffer, &(&1.pts != nil))
    {Enum.map(ready, &{&1.au, {&1.pts, &1.dts}}), %{state | buffer: rest}}
  end

  defp drain(state) do
    state = assign_all_pts(state)
    outputs = Enum.map(state.buffer, &{&1.au, {&1.pts, &1.dts}})
    {outputs, %{state | buffer: []}}
  end

  defp assign_all_pts(state) do
    if Enum.any?(state.buffer, &(&1.pts == nil)),
      do: state |> assign_next_pts() |> assign_all_pts(),
      else: state
  end
end
