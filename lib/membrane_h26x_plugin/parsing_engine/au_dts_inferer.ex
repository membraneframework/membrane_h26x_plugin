defmodule Membrane.H26x.ParsingEngine.AUDTSInferer do
  @moduledoc false

  alias Membrane.H26x.NALu
  alias Membrane.H26x.ParsingEngine.AUSplitter

  @type mode :: nil | :passthrough | :inference

  @type state :: %{
          mode: mode(),
          frame_duration: pos_integer() | nil,
          gop_anchor_poc: integer() | nil,
          gop_anchor_pts: integer() | nil,
          last_dts: integer() | nil,
          prev_pic_first_vcl_nalu: NALu.t() | nil,
          prev_pic_order_cnt_msb: integer()
        }

  @type timestamped_au ::
          {AUSplitter.access_unit(), pts :: integer() | nil, dts :: integer() | nil}

  @doc """
  Creates the initial DTS inference state.
  """
  @spec new() :: state()
  def new() do
    %{
      mode: nil,
      frame_duration: nil,
      gop_anchor_poc: nil,
      gop_anchor_pts: nil,
      last_dts: nil,
      prev_pic_first_vcl_nalu: nil,
      prev_pic_order_cnt_msb: 0
    }
  end

  @doc """
  Preserves supplied DTS values or infers missing DTS values from H265 POC and PTS.

  The stream mode is selected by the first valid access unit and cannot change
  afterwards. In inference mode, the first random-access picture starts the timing
  epoch and the next picture establishes the frame duration. Later random-access
  pictures retain that decode cadence unless their PTS indicates a discontinuity.
  """
  @spec infer_timestamps(module(), [AUSplitter.access_unit()], state()) ::
          {[timestamped_au()], state()}
  def infer_timestamps(module, access_units, state) do
    Enum.map_reduce(access_units, state, &infer_access_unit(module, &1, &2))
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

  defp infer_valid_access_unit(_module, au, _vcl_nalu, pts, dts, %{mode: nil} = state)
       when is_integer(dts) do
    {{au, pts, dts}, %{state | mode: :passthrough, last_dts: dts}}
  end

  defp infer_valid_access_unit(module, au, vcl_nalu, pts, nil, %{mode: nil} = state)
       when is_integer(pts) do
    state = %{state | mode: :inference}
    infer_valid_access_unit(module, au, vcl_nalu, pts, nil, state)
  end

  defp infer_valid_access_unit(_module, _au, _vcl_nalu, _pts, nil, %{mode: nil}) do
    raise ArgumentError,
          "cannot infer H265 DTS: the first access unit has neither PTS nor DTS"
  end

  defp infer_valid_access_unit(_module, au, _vcl_nalu, pts, dts, %{mode: :passthrough} = state)
       when is_integer(dts) do
    {{au, pts, dts}, %{state | last_dts: dts}}
  end

  defp infer_valid_access_unit(_module, _au, _vcl_nalu, _pts, nil, %{mode: :passthrough}) do
    raise ArgumentError,
          "cannot infer H265 DTS: DTS disappeared after the stream started with supplied DTS"
  end

  defp infer_valid_access_unit(_module, _au, _vcl_nalu, _pts, dts, %{mode: :inference})
       when is_integer(dts) do
    raise ArgumentError,
          "cannot infer H265 DTS: supplied DTS appeared after the stream started without DTS"
  end

  defp infer_valid_access_unit(_module, _au, _vcl_nalu, nil, nil, %{mode: :inference}) do
    raise ArgumentError, "cannot infer H265 DTS: an access unit is missing PTS"
  end

  defp infer_valid_access_unit(module, au, vcl_nalu, pts, nil, %{mode: :inference} = state) do
    if random_access?(vcl_nalu) do
      start_timing_epoch(module, au, vcl_nalu, pts, state)
    else
      continue_timing_epoch(module, au, vcl_nalu, pts, state)
    end
  end

  defp start_timing_epoch(module, au, vcl_nalu, pts, state) do
    poc_state = initialize_poc_state(vcl_nalu, state)
    {poc, poc_state} = module.calculate_poc(vcl_nalu, poc_state)

    {dts, frame_duration} = epoch_dts_and_duration!(pts, vcl_nalu, state)

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
          "cannot infer H265 DTS: the stream does not start with a random-access picture"
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
            "cannot infer H265 DTS: PTS and POC do not establish a positive frame duration"
    end
  end

  defp initialize_poc_state(vcl_nalu, %{prev_pic_first_vcl_nalu: nil} = state),
    do: %{state | prev_pic_first_vcl_nalu: vcl_nalu}

  defp initialize_poc_state(_vcl_nalu, state), do: state

  defp epoch_dts_and_duration!(pts, _vcl_nalu, %{last_dts: nil}), do: {pts, nil}

  defp epoch_dts_and_duration!(pts, _vcl_nalu, %{frame_duration: nil} = state) do
    duration = pts - state.gop_anchor_pts

    if duration > 0 do
      {state.last_dts + duration, duration}
    else
      raise ArgumentError,
            "cannot infer H265 DTS: consecutive random-access pictures do not establish a positive frame duration"
    end
  end

  defp epoch_dts_and_duration!(pts, vcl_nalu, state) do
    expected_dts = state.last_dts + state.frame_duration
    max_reorder = Map.get(vcl_nalu.parsed_fields, :sps_max_num_reorder_pics, 0)
    max_expected_offset = (max_reorder + 1) * state.frame_duration

    cond do
      abs(pts - expected_dts) <= max_expected_offset ->
        {expected_dts, state.frame_duration}

      pts > state.last_dts ->
        {pts, state.frame_duration}

      true ->
        raise ArgumentError,
              "cannot infer H265 DTS: a random-access picture starts a non-monotonic timing epoch"
    end
  end

  defp random_access?(vcl_nalu),
    do: vcl_nalu.type in [:bla_w_lp, :bla_w_radl, :bla_n_lp, :idr_w_radl, :idr_n_lp, :cra]
end
