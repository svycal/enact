defmodule Enact.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/savvycal/enact"

  def project do
    [
      app: :enact,
      version: @version,
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      consolidate_protocols: Mix.env() != :test,
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "Enact",
      description: "A thin, behaviour-based action layer for application write operations.",
      package: package(),
      docs: docs()
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ecto, "~> 3.10"},
      {:telemetry, "~> 1.0"},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "Enact",
      source_url: @source_url,
      extras: ["README.md", "spec.md": [title: "Design Specification"]]
    ]
  end
end
