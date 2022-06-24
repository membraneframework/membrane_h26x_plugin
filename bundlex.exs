defmodule Membrane.Element.Template.BundlexProject do
  use Bundlex.Project

  def project do
    [
      natives: natives(Bundlex.platform())
    ]
  end

  defp natives(_platform) do
    [
      native: [
        sources: ["native.c"],
        deps: [unifex: :unifex],
        interface: [:nif, :cnode],
        preprocessor: Unifex
      ]
    ]
  end
end
