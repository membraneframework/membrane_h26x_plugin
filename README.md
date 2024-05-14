# Membrane H26x Plugin

[![Hex.pm](https://img.shields.io/hexpm/v/membrane_h264_plugin.svg)](https://hex.pm/packages/membrane_h264_plugin)
[![API Docs](https://img.shields.io/badge/api-docs-yellow.svg?style=flat)](https://hexdocs.pm/membrane_h264_plugin)
[![CircleCI](https://circleci.com/gh/membraneframework/membrane_h264_plugin.svg?style=svg)](https://circleci.com/gh/membraneframework/membrane_h264_plugin)

Membrane H.264 and H.265 parsers.
It is a pair of Membrane elements responsible for parsing the incoming H.264 and H.265 streams. The parsing is done as a sequence of the following steps:
* splitting the stream into stream NAL units
* Parsing the NAL unit headers, so that to read the type of the NAL unit
* Parsing the NAL unit body with the appropriate scheme, based on the NAL unit type read in the step before
* Aggregating the NAL units into a stream of *access units*

The output of the element is the incoming binary payload, enriched with the metadata describing the division of the payload into *access units*.

It is part of [Membrane Multimedia Framework](https://membraneframework.org).

## Installation

The package can be installed by adding `membrane_h26x_plugin` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:membrane_h26x_plugin, "~> 0.10.2"}
  ]
end
```

## Usage

The following pipeline takes H264 file, parses it, and then decodes it to the raw video.

```elixir
defmodule Decoding.Pipeline do
  use Membrane.Pipeline

  alias Membrane.{File, H264}

  @impl true
  def handle_init(_ctx, _opts) do
    spec =
      child(:source, %File.Source{location: "test/fixtures/input-10-720p-main.h264"})
      |> child(:parser, H264.Parser)
      |> child(:decoder, H264.FFmpeg.Decoder)
      |> child(:sink, %File.Sink{location: "output.raw"})

    {[spec: spec], nil}
  end

  @impl true
  def handle_element_end_of_stream(:sink, _ctx_, state) do
    {[terminate: :normal], state}
  end
end
```


## Copyright and License

Copyright 2022, [Software Mansion](https://swmansion.com/?utm_source=git&utm_medium=readme&utm_campaign=membrane_h264_plugin)

[![Software Mansion](https://logo.swmansion.com/logo?color=white&variant=desktop&width=200&tag=membrane-github)](https://swmansion.com/?utm_source=git&utm_medium=readme&utm_campaign=membrane_h264_plugin)

Licensed under the [Apache License, Version 2.0](LICENSE)
