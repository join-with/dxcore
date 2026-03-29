defmodule DxCore.Agents.CLI do
  @moduledoc """
  Escript entry point. Supports two modes:
  - `agent` -- connects to coordinator, executes assigned tasks
  - `dispatch` -- runs turbo --dry=json, submits graph to coordinator
  """

  @doc false
  def http_to_ws(url) do
    url
    |> String.replace(~r{^https://}, "wss://")
    |> String.replace(~r{^http://}, "ws://")
  end

  @doc """
  Monitor a process and block until it exits, returning the exit reason.

  Uses `Process.monitor/1` (not link) so the caller is not killed if
  the monitored process exits abnormally.
  """
  def await_exit(pid) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, reason} -> reason
    end
  end

  def main(args) do
    # Ensure required applications are started (needed for escript context)
    {:ok, _} = Application.ensure_all_started(:jason)
    {:ok, _} = Application.ensure_all_started(:slipstream)
    {:ok, _} = Application.ensure_all_started(:req)

    case args do
      ["agent" | rest] ->
        DxCore.Agents.CLI.Agent.run(rest)

      ["dispatch" | rest] ->
        DxCore.Agents.CLI.Dispatcher.run(rest)

      ["ci" | rest] ->
        DxCore.Agents.CLI.Ci.run(rest)

      ["config", "--show" | rest] ->
        run_config_show(rest)

      _ ->
        IO.puts("Usage: dxcore-agents <agent|dispatch|ci|config> [options]")
        System.halt(1)
    end
  end

  defp run_config_show(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [work_dir: :string], aliases: [w: :work_dir])
    work_dir = Keyword.get(opts, :work_dir, ".")
    config = DxCore.Agents.ShardConfig.scan(work_dir)

    case DxCore.Agents.ShardConfig.format_summary(config) do
      [] ->
        IO.puts("No shard configuration found. Add dxcore.json files to package directories.")

      lines ->
        IO.puts("Shard configuration:")
        Enum.each(lines, &IO.puts("  #{&1}"))
    end
  end
end
