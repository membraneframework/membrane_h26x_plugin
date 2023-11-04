defmodule Membrane.H26x.AUTimestampGenerator do
  @moduledoc false

  alias Membrane.H26x.{AUSplitter, NALu}

  @type framerate :: {frames :: pos_integer(), seconds :: pos_integer()}

  @type state :: %{
          framerate: framerate,
          max_frame_reorder: 0..15,
          au_counter: non_neg_integer(),
          key_frame_au_idx: non_neg_integer(),
          prev_pic_first_vcl_nalu: NALu.t() | nil,
          prev_pic_order_cnt_msb: integer()
        }

  @callback get_first_vcl_nalu(AUSplitter.access_unit()) :: NALu.t()
  @callback calculate_poc(NALu.t(), state()) :: {non_neg_integer(), state()}

  @optional_callbacks get_first_vcl_nalu: 1, calculate_poc: 2

  defmacro __using__(_options) do
    quote location: :keep do
      @behaviour unquote(__MODULE__)

      @typep config :: %{
               :framerate => unquote(__MODULE__).framerate,
               optional(:add_dts_offset) => boolean()
             }

      @spec new(config()) :: unquote(__MODULE__).state()
      def new(config) do
        # To make sure that PTS >= DTS at all times, we take maximal possible
        # frame reorder (which is 15 according to the spec) and subtract
        # `max_frame_reorder * frame_duration` from each frame's DTS.
        # This behaviour can be disabled by setting `add_dts_offset: false`.
        max_frame_reorder = if Map.get(config, :add_dts_offset, true), do: 15, else: 0

        %{
          framerate: config.framerate,
          max_frame_reorder: max_frame_reorder,
          au_counter: 0,
          key_frame_au_idx: 0,
          prev_pic_first_vcl_nalu: nil,
          prev_pic_order_cnt_msb: 0
        }
      end

      @spec generate_ts_with_constant_framerate(
              AUSplitter.access_unit(),
              unquote(__MODULE__).state()
            ) ::
              {{pts :: non_neg_integer(), dts :: non_neg_integer()}, unquote(__MODULE__).state()}
      def generate_ts_with_constant_framerate(au, state) do
        %{
          au_counter: au_counter,
          key_frame_au_idx: key_frame_au_idx,
          max_frame_reorder: max_frame_reorder,
          framerate: {frames, seconds}
        } = state

        first_vcl_nalu = get_first_vcl_nalu(au)
        {poc, state} = calculate_poc(first_vcl_nalu, state)
        key_frame_au_idx = if poc == 0, do: au_counter, else: key_frame_au_idx
        pts = div((key_frame_au_idx + poc) * seconds * Membrane.Time.second(), frames)
        dts = div((au_counter - max_frame_reorder) * seconds * Membrane.Time.second(), frames)

        state = %{
          state
          | au_counter: au_counter + 1,
            key_frame_au_idx: key_frame_au_idx
        }

        {{pts, dts}, state}
      end

      @impl true
      def get_first_vcl_nalu(au) do
        raise "get_first_vcl_nalu/1 not implemented"
      end

      @impl true
      def calculate_poc(first_vcl_nalu, state) do
        raise "calculate_poc/2 not implemented"
      end

      defoverridable get_first_vcl_nalu: 1, calculate_poc: 2
    end
  end
end
