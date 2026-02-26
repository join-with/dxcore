defmodule DxCore.Agents.CLI.MixProject do
  use Mix.Project

  def project do
    [
      app: :dxcore_agents_cli,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      escript: [main_module: DxCore.Agents.CLI],
      releases: releases(),
      deps: deps()
    ]
  end

  def application do
    [
      mod: {DxCore.Agents.CLI.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:jason, "~> 1.2"},
      {:slipstream, "~> 1.0"},
      {:req, "~> 0.5"},
      {:burrito, "~> 1.0"}
    ]
  end

  defp releases do
    [
      dxcore_agents_cli: [
        steps: [:assemble, &Burrito.wrap/1],
        burrito: [
          targets: [
            linux: [os: :linux, cpu: :x86_64]
          ]
        ]
      ]
    ]
  end
end
