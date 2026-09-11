defmodule Membrane.H26x.ParsingEngine.AUTimestampGenerator do
  @moduledoc false

  alias Membrane.H26x.NALu
  alias Membrane.H26x.ParsingEngine.AUSplitter

  @type mode :: :generate_best_effort_timestamps | :infer_dts_from_pts | :passthrough

  @type framerate :: {frames :: pos_integer(), seconds :: pos_integer()}

  @type config :: %{
          :framerate => framerate(),
          optional(:add_dts_offset) => boolean()
        }

  @type buffer_entry :: %{
          id: non_neg_integer(),
          au: AUSplitter.access_unit(),
          poc: integer(),
          dts: integer(),
          pts: integer() | nil
        }

  @type state :: %{
          :mode => mode(),
          optional(:framerate) => framerate(),
          optional(:max_frame_reorder) => non_neg_integer(),
          optional(:au_counter) => non_neg_integer(),
          optional(:pts_counter) => non_neg_integer(),
          optional(:buffer_depth) => non_neg_integer() | nil,
          optional(:buffer) => [buffer_entry()],
          optional(:prev_pic_first_vcl_nalu) => NALu.t() | nil,
          optional(:prev_pic_order_cnt_msb) => integer(),
          optional(:dts_source) => nil | :supplied | :inferred,
          optional(:frame_duration) => pos_integer() | nil,
          optional(:gop_anchor_poc) => integer() | nil,
          optional(:gop_anchor_pts) => integer() | nil,
          optional(:last_dts) => integer() | nil
        }

  @type timestamp :: integer() | nil
  @type timestamped_au ::
          {AUSplitter.access_unit(), pts :: timestamp(), dts :: timestamp()}

  @doc """
  Returns the maximum number of frames that may be reordered for the codec.
  """
  @callback max_frame_reorder() :: pos_integer()

  @doc """
  Returns the first VCL (slice) NALu of the access unit, or `nil` if there is none.
  """
  @callback get_first_vcl_nalu(AUSplitter.access_unit()) :: NALu.t() | nil

  @doc """
  Computes the picture order count of the given VCL NALu, returning it with the updated state.
  """
  @callback calculate_poc(NALu.t(), state()) :: {integer(), state()}

  @doc """
  Returns the reorder buffer depth implied by the VCL NALu's parameters.
  """
  @callback reorder_buffer_depth(NALu.t(), state()) :: non_neg_integer()

  @doc """
  Returns whether the picture can anchor a DTS inference timing epoch.
  Required only for codecs supporting DTS inference.
  """
  @callback random_access?(NALu.t()) :: boolean()

  @optional_callbacks random_access?: 1

  @doc """
  Creates the initial state of the timestamp generator.
  """
  @spec new(module(), mode(), config() | %{}) :: state()
  def new(module, mode, config \\ %{})

  def new(module, :generate_best_effort_timestamps, config) do
    # To make sure that PTS >= DTS at all times, we take the maximal possible
    # frame reorder and subtract `max_frame_reorder * frame_duration` from each
    # frame's DTS. This behaviour can be disabled by setting `add_dts_offset: false`.
    max_frame_reorder =
      if Map.get(config, :add_dts_offset, true), do: module.max_frame_reorder(), else: 0

    %{
      mode: :generate_best_effort_timestamps,
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

  def new(_module, :infer_dts_from_pts, _config) do
    %{
      mode: :infer_dts_from_pts,
      dts_source: nil,
      frame_duration: nil,
      gop_anchor_poc: nil,
      gop_anchor_pts: nil,
      last_dts: nil,
      prev_pic_first_vcl_nalu: nil,
      prev_pic_order_cnt_msb: 0
    }
  end

  def new(_module, :passthrough, _config), do: %{mode: :passthrough}

  @doc """
  Processes access units in decode order using the configured timestamp mode.

  Best-effort generation applies only to `:bytestream` input alignment (the
  default). Aligned input preserves timestamps without advancing generator state.
  With `flush?: true`, buffered best-effort output is drained after processing.
  Inference and passthrough emit immediately and have no output to drain.

  In inference mode, the first valid access unit selects supplied or inferred DTS
  for the stream. The first random-access picture anchors inference and the next
  picture establishes cadence. Later random-access pictures retain that cadence
  unless their PTS indicates a discontinuity.
  """
  @spec generate_timestamps(
          module(),
          [AUSplitter.access_unit()],
          [flush?: boolean(), input_alignment: :bytestream | :nalu | :au],
          state()
        ) :: {[timestamped_au()], state()}
  def generate_timestamps(module, access_units, options \\ [], state)

  def generate_timestamps(
        module,
        access_units,
        options,
        %{mode: :generate_best_effort_timestamps} = state
      ) do
    if Keyword.get(options, :input_alignment, :bytestream) == :bytestream do
      {ready, state} =
        Enum.flat_map_reduce(access_units, state, fn au, state ->
          put_access_unit(module, au, state)
        end)

      {drained, state} =
        if Keyword.get(options, :flush?, false), do: drain(state), else: {[], state}

      {ready ++ drained, state}
    else
      {preserve_timestamps(module, access_units), state}
    end
  end

  def generate_timestamps(module, access_units, _options, %{mode: :infer_dts_from_pts} = state) do
    Enum.map_reduce(access_units, state, &infer_access_unit(module, &1, &2))
  end

  def generate_timestamps(module, access_units, _options, %{mode: :passthrough} = state) do
    {preserve_timestamps(module, access_units), state}
  end

  defp preserve_timestamps(module, access_units) do
    Enum.map(access_units, fn au ->
      first_vcl_nalu = module.get_first_vcl_nalu(au)
      {pts, dts} = if first_vcl_nalu, do: first_vcl_nalu.timestamps, else: {nil, nil}
      {au, pts, dts}
    end)
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

  defp infer_access_unit(module, au, state) do
    first_vcl_nalu = module.get_first_vcl_nalu(au)

    if is_nil(first_vcl_nalu) or Enum.any?(au, &(&1.status != :valid)) do
      {{au, nil, nil}, state}
    else
      {pts, dts} = first_vcl_nalu.timestamps
      infer_valid_access_unit(module, au, first_vcl_nalu, pts, dts, state)
    end
  end

  defp infer_valid_access_unit(_module, au, _vcl_nalu, pts, dts, %{dts_source: nil} = state)
       when is_integer(dts) do
    {{au, pts, dts}, %{state | dts_source: :supplied, last_dts: dts}}
  end

  defp infer_valid_access_unit(module, au, vcl_nalu, pts, nil, %{dts_source: nil} = state)
       when is_integer(pts) do
    state = %{state | dts_source: :inferred}
    infer_valid_access_unit(module, au, vcl_nalu, pts, nil, state)
  end

  defp infer_valid_access_unit(_module, _au, _vcl_nalu, _pts, nil, %{dts_source: nil}) do
    raise ArgumentError,
          "cannot infer DTS: the first access unit has neither PTS nor DTS"
  end

  defp infer_valid_access_unit(_module, au, _vcl_nalu, pts, dts, %{dts_source: :supplied} = state)
       when is_integer(dts) do
    {{au, pts, dts}, %{state | last_dts: dts}}
  end

  defp infer_valid_access_unit(_module, _au, _vcl_nalu, _pts, nil, %{dts_source: :supplied}) do
    raise ArgumentError,
          "cannot infer DTS: DTS disappeared after the stream started with supplied DTS"
  end

  defp infer_valid_access_unit(_module, _au, _vcl_nalu, _pts, dts, %{dts_source: :inferred})
       when is_integer(dts) do
    raise ArgumentError,
          "cannot infer DTS: supplied DTS appeared after the stream started without DTS"
  end

  defp infer_valid_access_unit(_module, _au, _vcl_nalu, nil, nil, %{dts_source: :inferred}) do
    raise ArgumentError, "cannot infer DTS: an access unit is missing PTS"
  end

  defp infer_valid_access_unit(module, au, vcl_nalu, pts, nil, %{dts_source: :inferred} = state) do
    if module.random_access?(vcl_nalu) do
      start_timing_epoch(module, au, vcl_nalu, pts, state)
    else
      continue_timing_epoch(module, au, vcl_nalu, pts, state)
    end
  end

  defp start_timing_epoch(module, au, vcl_nalu, pts, state) do
    poc_state = initialize_poc_state(vcl_nalu, state)
    {poc, poc_state} = module.calculate_poc(vcl_nalu, poc_state)

    {dts, frame_duration} = epoch_dts_and_duration!(module, pts, vcl_nalu, state)

    state = %{
      poc_state
      | frame_duration: frame_duration,
        gop_anchor_poc: poc,
        gop_anchor_pts: pts,
        last_dts: dts
    }

    {{au, pts, dts}, state}
  end

  defp continue_timing_epoch(_module, _au, _vcl_nalu, _pts, %{gop_anchor_pts: nil}) do
    raise ArgumentError,
          "cannot infer DTS: the stream does not start with a random-access picture"
  end

  defp continue_timing_epoch(module, au, vcl_nalu, pts, %{frame_duration: nil} = state) do
    {poc, state} = module.calculate_poc(vcl_nalu, state)
    frame_duration = infer_frame_duration!(pts, poc, state)
    dts = state.last_dts + frame_duration

    {{au, pts, dts}, %{state | frame_duration: frame_duration, last_dts: dts}}
  end

  defp continue_timing_epoch(module, au, vcl_nalu, pts, state) do
    {_poc, state} = module.calculate_poc(vcl_nalu, state)
    dts = state.last_dts + state.frame_duration
    {{au, pts, dts}, %{state | last_dts: dts}}
  end

  defp infer_frame_duration!(pts, poc, state) do
    pts_delta = pts - state.gop_anchor_pts
    poc_delta = poc - state.gop_anchor_poc

    duration =
      cond do
        poc_delta == 0 and pts_delta > 0 -> pts_delta
        poc_delta != 0 and pts_delta * poc_delta > 0 -> div(abs(pts_delta), abs(poc_delta))
        true -> 0
      end

    if duration > 0 do
      duration
    else
      raise ArgumentError,
            "cannot infer DTS: PTS and POC do not establish a positive frame duration"
    end
  end

  defp initialize_poc_state(vcl_nalu, %{prev_pic_first_vcl_nalu: nil} = state),
    do: %{state | prev_pic_first_vcl_nalu: vcl_nalu}

  defp initialize_poc_state(_vcl_nalu, state), do: state

  defp epoch_dts_and_duration!(_module, pts, _vcl_nalu, %{last_dts: nil}), do: {pts, nil}

  defp epoch_dts_and_duration!(_module, pts, _vcl_nalu, %{frame_duration: nil} = state) do
    duration = pts - state.gop_anchor_pts

    if duration > 0 do
      {state.last_dts + duration, duration}
    else
      raise ArgumentError,
            "cannot infer DTS: consecutive random-access pictures do not establish a positive frame duration"
    end
  end

  defp epoch_dts_and_duration!(module, pts, vcl_nalu, state) do
    expected_dts = state.last_dts + state.frame_duration
    max_reorder = module.reorder_buffer_depth(vcl_nalu, state)
    max_expected_offset = (max_reorder + 1) * state.frame_duration

    cond do
      abs(pts - expected_dts) <= max_expected_offset ->
        {expected_dts, state.frame_duration}

      pts > state.last_dts ->
        {pts, state.frame_duration}

      true ->
        raise ArgumentError,
              "cannot infer DTS: a random-access picture starts a non-monotonic timing epoch"
    end
  end
end

defmodule Membrane.H264.AUTimestampGenerator do
  @moduledoc false

  @behaviour Membrane.H26x.ParsingEngine.AUTimestampGenerator

  require Membrane.H264.NALuTypes, as: NALuTypes

  @impl true
  def max_frame_reorder(), do: 15

  @impl true
  def get_first_vcl_nalu(au) do
    Enum.find(au, &NALuTypes.is_vcl_nalu_type(&1.type))
  end

  @impl true
  def reorder_buffer_depth(vcl_nalu, _state) do
    fields = vcl_nalu.parsed_fields

    cond do
      fields.profile in [:baseline, :constrained_baseline] ->
        0

      fields.pic_order_cnt_type == 2 ->
        0

      fields[:vui_parameters_present_flag] == 1 and fields[:bitstream_restriction_flag] == 1 ->
        fields.max_num_reorder_frames

      true ->
        max_frame_reorder()
    end
  end

  @impl true
  # Calculate picture order count according to section 8.2.1 of the ITU-T H264 specification
  def calculate_poc(%{parsed_fields: %{pic_order_cnt_type: 0}} = vcl_nalu, state) do
    max_pic_order_cnt_lsb = 2 ** (vcl_nalu.parsed_fields.log2_max_pic_order_cnt_lsb_minus4 + 4)

    {prev_pic_order_cnt_msb, prev_pic_order_cnt_lsb} =
      if vcl_nalu.type == :idr do
        {0, 0}
      else
        # As described in the spec, we should check for presence of the
        # memory_management_control_operation syntax element equal to 5
        # in the previous reference picture and calculate prev_pic_order_cnt_*sb
        # values accordingly if it's there. Since getting to that information
        # is quite a pain in the ass, we don't do that and assume it's not
        # there and it seems to work ¯\_(ツ)_/¯ However, it may happen not to work
        # for some streams and we may generate invalid timestamps because of that.
        # If that happens, may have to implement the aforementioned lacking part.

        previous_vcl_nalu = state.prev_pic_first_vcl_nalu || vcl_nalu
        {state.prev_pic_order_cnt_msb, previous_vcl_nalu.parsed_fields.pic_order_cnt_lsb}
      end

    pic_order_cnt_lsb = vcl_nalu.parsed_fields.pic_order_cnt_lsb

    pic_order_cnt_msb =
      cond do
        pic_order_cnt_lsb < prev_pic_order_cnt_lsb and
            prev_pic_order_cnt_lsb - pic_order_cnt_lsb >= max_pic_order_cnt_lsb / 2 ->
          prev_pic_order_cnt_msb + max_pic_order_cnt_lsb

        pic_order_cnt_lsb > prev_pic_order_cnt_lsb and
            pic_order_cnt_lsb - prev_pic_order_cnt_lsb > max_pic_order_cnt_lsb / 2 ->
          prev_pic_order_cnt_msb - max_pic_order_cnt_lsb

        true ->
          prev_pic_order_cnt_msb
      end

    pic_order_cnt =
      if get_slice_type(vcl_nalu) == :frame do
        top_field_order_cnt = pic_order_cnt_msb + pic_order_cnt_lsb

        bottom_field_order_cnt =
          top_field_order_cnt + vcl_nalu.parsed_fields.delta_pic_order_cnt_bottom

        min(top_field_order_cnt, bottom_field_order_cnt)
      else
        pic_order_cnt_msb + pic_order_cnt_lsb
      end

    {div(pic_order_cnt, 2),
     %{state | prev_pic_order_cnt_msb: pic_order_cnt_msb, prev_pic_first_vcl_nalu: vcl_nalu}}
  end

  @impl true
  def calculate_poc(%{parsed_fields: %{pic_order_cnt_type: 1}}, _state) do
    raise "Timestamp generation error: unsupported stream. Unsupported field value pic_order_cnt_type=1"
  end

  @impl true
  def calculate_poc(
        %{parsed_fields: %{pic_order_cnt_type: 2, frame_num: frame_num}} = vcl_nalu,
        state
      ) do
    {frame_num, %{state | prev_pic_first_vcl_nalu: vcl_nalu}}
  end

  defp get_slice_type(vcl_nalu) do
    case vcl_nalu.parsed_fields do
      %{frame_mbs_only_flag: 1} -> :frame
      %{field_pic_flag: 0} -> :frame
      %{bottom_field_flag: 1} -> :bottom_field
      _other -> :top_field
    end
  end
end

defmodule Membrane.H265.AUTimestampGenerator do
  @moduledoc false

  @behaviour Membrane.H26x.ParsingEngine.AUTimestampGenerator

  require Membrane.H265.NALuTypes, as: NALuTypes

  @impl true
  def random_access?(vcl_nalu),
    do: vcl_nalu.type in [:bla_w_lp, :bla_w_radl, :bla_n_lp, :idr_w_radl, :idr_n_lp, :cra]

  @impl true
  def max_frame_reorder(), do: 15

  @impl true
  def get_first_vcl_nalu(au) do
    Enum.find(au, &NALuTypes.is_vcl_nalu_type(&1.type))
  end

  @impl true
  def reorder_buffer_depth(vcl_nalu, _state) do
    Map.get(vcl_nalu.parsed_fields, :sps_max_num_reorder_pics, 0)
  end

  @impl true
  # Calculate picture order count according to section 8.3.1 of the ITU-T H265 specification
  def calculate_poc(vcl_nalu, state) do
    max_pic_order_cnt_lsb = 2 ** (vcl_nalu.parsed_fields.log2_max_pic_order_cnt_lsb_minus4 + 4)

    # We exclude CRA pictures from IRAP pictures since we have no way
    # to assert the value of the flag NoRaslOutputFlag.
    # If the CRA is the first access unit in the bytestream, the flag would be
    # equal to 1 which reset the POC counter, and that condition is
    # satisfied here since the initial value for prev_pic_order_cnt_msb and
    # prev_pic_order_cnt_lsb are 0
    {prev_pic_order_cnt_msb, prev_pic_order_cnt_lsb} =
      if vcl_nalu.parsed_fields.nal_unit_type in 16..20 do
        {0, 0}
      else
        {state.prev_pic_order_cnt_msb,
         state.prev_pic_first_vcl_nalu.parsed_fields.pic_order_cnt_lsb}
      end

    pic_order_cnt_lsb = vcl_nalu.parsed_fields.pic_order_cnt_lsb

    pic_order_cnt_msb =
      cond do
        pic_order_cnt_lsb < prev_pic_order_cnt_lsb and
            prev_pic_order_cnt_lsb - pic_order_cnt_lsb >= div(max_pic_order_cnt_lsb, 2) ->
          prev_pic_order_cnt_msb + max_pic_order_cnt_lsb

        pic_order_cnt_lsb > prev_pic_order_cnt_lsb and
            pic_order_cnt_lsb - prev_pic_order_cnt_lsb > div(max_pic_order_cnt_lsb, 2) ->
          prev_pic_order_cnt_msb - max_pic_order_cnt_lsb

        true ->
          prev_pic_order_cnt_msb
      end

    {prev_pic_first_vcl_nalu, prev_pic_order_cnt_msb} =
      if vcl_nalu.type in [:radl_r, :radl_n, :rasl_r, :rasl_n] or
           vcl_nalu.parsed_fields.nal_unit_type in 0..15//2 do
        {state.prev_pic_first_vcl_nalu, prev_pic_order_cnt_msb}
      else
        {vcl_nalu, pic_order_cnt_msb}
      end

    {pic_order_cnt_msb + pic_order_cnt_lsb,
     %{
       state
       | prev_pic_order_cnt_msb: prev_pic_order_cnt_msb,
         prev_pic_first_vcl_nalu: prev_pic_first_vcl_nalu
     }}
  end
end
