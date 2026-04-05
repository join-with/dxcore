defmodule DxCore.Agents.CLI.Help do
  @moduledoc false

  @commands [
    {"agent", DxCore.Agents.CLI.Agent},
    {"dispatch", DxCore.Agents.CLI.Dispatcher},
    {"ci", DxCore.Agents.CLI.Ci},
    {"config", DxCore.Agents.CLI.Config}
  ]

  def print_top_level do
    IO.puts("dxcore - Distributed CI/CD task execution for monorepos")
    IO.puts("")
    IO.puts("Usage: dxcore <command> [options]")
    IO.puts("")
    IO.puts("Commands:")

    for {name, mod} <- @commands do
      desc = mod.shortdoc()
      IO.puts("  #{String.pad_trailing(name, 10)}#{desc}")
    end

    IO.puts("")
    IO.puts("Run 'dxcore <command> --help' for more information.")
  end

  def print_for(module) do
    IO.puts(module.help())
  end
end
