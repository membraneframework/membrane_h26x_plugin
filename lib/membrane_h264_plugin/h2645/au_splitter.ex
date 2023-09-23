defmodule Membrane.H2645.AUSplitter do
  @moduledoc """
  A behaviour module to split NALus into access units
  """

  alias Membrane.H2645.NALu

  @typedoc """
  A type representing an access unit - a list of logically associated NAL units.
  """
  @type access_unit() :: list(NALu.t())

  @type state :: term()

  @callback new() :: state()
  @callback split([NALu.t()], boolean(), state()) :: {[access_unit()], state()}
end
