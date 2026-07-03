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

defmodule Membrane.H264.AUTimestampGenerator do
  @moduledoc false

  @behaviour Membrane.H26x.AUTimestampGenerator

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

  @behaviour Membrane.H26x.AUTimestampGenerator

  require Membrane.H265.NALuTypes, as: NALuTypes

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
