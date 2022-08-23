# Membrane H264 Plugin

[![Hex.pm](https://img.shields.io/hexpm/v/membrane_h264_plugin.svg)](https://hex.pm/packages/membrane_h264_plugin)
[![API Docs](https://img.shields.io/badge/api-docs-yellow.svg?style=flat)](https://hexdocs.pm/membrane_h264_plugin)
[![CircleCI](https://circleci.com/gh/membraneframework/membrane_h264_plugin.svg?style=svg)](https://circleci.com/gh/membraneframework/membrane_h264_plugin)

Membrane H264 parser.

It is part of [Membrane Multimedia Framework](https://membraneframework.org).

## Installation

The package can be installed by adding `membrane_h264_plugin` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:membrane_h264_plugin, "~> 0.1.0"}
  ]
end
```

## Usage

The following pipeline takes H264 file, parses it, and then decodes it to the raw video.

```elixir
defmodule Decoding.Pipeline do
  use Membrane.Pipeline

  alias Membrane.{File, H264, ParentSpec}

  @impl true
  def handle_init(_ptions) do
    children = [
      source: %File.Source{chunk_size: 40_960, location: "input.h264"},
      parser: H264.Parser,
      decoder: H264.FFmpeg.Decoder,
      sink: %File.Sink{location: "output.raw"}
    ]

    {{:ok, [spec: %ParentSpec{links: ParentSpec.link_linear(children)}, playback: :playing]}, nil}
  end

  @impl true
  def handle_element_end_of_stream(:sink, _ctx_, _state) do
    {{:ok, playback: :stopped}, nil}
  end
end
```


## Copyright and License

Copyright 2022, [Software Mansion](https://swmansion.com/?utm_source=git&utm_medium=readme&utm_campaign=membrane_h264_plugin)

[![Software Mansion](https://logo.swmansion.com/logo?color=white&variant=desktop&width=200&tag=membrane-github)](https://swmansion.com/?utm_source=git&utm_medium=readme&utm_campaign=membrane_h264_plugin)

Licensed under the [Apache License, Version 2.0](LICENSE)
