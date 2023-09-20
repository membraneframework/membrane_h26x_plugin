defmodule Membrane.H264.Plugin.Mixfile do
  use Mix.Project

  @version "0.7.3"
  @github_url "https://github.com/membraneframework-labs/membrane_h264_plugin"

  def project do
    [
      app: :membrane_h264_plugin,
      version: @version,
      elixir: "~> 1.13",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: dialyzer(),

      # hex
      description: "Membrane H264 parser",
      package: package(),

      # docs
      name: "Membrane H264 plugin",
      source_url: @github_url,
      homepage_url: "https://membrane.stream",
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: []
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:membrane_core, "~> 0.12.7"},
      {:membrane_h264_format, "~> 0.6.0"},
      {:bunch, "~> 1.4"},
      {:membrane_stream_plugin, "~> 0.3.1", only: :test},
      {:membrane_file_plugin, "~> 0.14.0", only: :test},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false},
      {:dialyxir, ">= 0.0.0", only: :dev, runtime: false},
      {:credo, ">= 0.0.0", only: :dev, runtime: false}
    ]
  end

  defp dialyzer() do
    opts = [
      flags: [:error_handling]
    ]

    if System.get_env("CI") == "true" do
      # Store PLTs in cacheable directory for CI
      [plt_local_path: "priv/plts", plt_core_path: "priv/plts"] ++ opts
    else
      opts
    end
  end

  defp package do
    [
      maintainers: ["Membrane Team"],
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @github_url,
        "Membrane Framework Homepage" => "https://membrane.stream"
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "LICENSE"],
      formatters: ["html"],
      source_ref: "v#{@version}",
      filter_modules: "Membrane\.H264\.Parser",
      nest_modules_by_prefix: [Membrane.H264.Parser]
    ]
  end
end
