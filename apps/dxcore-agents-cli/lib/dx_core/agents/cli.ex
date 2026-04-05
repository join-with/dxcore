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

    try do
      case args do
        ["--help"] ->
          help_and_exit()

        ["-h"] ->
          help_and_exit()

        [] ->
          help_and_exit()

        ["agent" | rest] ->
          DxCore.Agents.CLI.Agent.run(rest)

        ["dispatch" | rest] ->
          DxCore.Agents.CLI.Dispatcher.run(rest)

        ["ci" | rest] ->
          DxCore.Agents.CLI.Ci.run(rest)

        ["config" | rest] ->
          DxCore.Agents.CLI.Config.run(rest)

        _ ->
          IO.puts("Unknown command: #{List.first(args)}")
          IO.puts("Run 'dxcore --help' for usage information.")
          System.halt(1)
      end
    catch
      # Subcommands throw(:help) instead of calling System.halt(0) directly
      # so that tests can intercept help exits without halting the BEAM.
      :throw, :help -> System.halt(0)
    end
  end

  defp help_and_exit do
    DxCore.Agents.CLI.Help.print_top_level()
    throw(:help)
  end
end
