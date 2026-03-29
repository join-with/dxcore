defmodule DxCore.Agents.BuildSystem do
  @moduledoc """
  Behaviour for build system adapters.

  Each adapter normalizes a build system's task graph JSON and provides
  execution commands for the coordinator's expected format.
  """

  @doc """
  Parse a build system's JSON output into normalized task maps.

  Accepts the raw JSON string from the build system's introspection command
  (e.g. `turbo run build --dry=json` or `nx run-many --graph=stdout`).

  Returns `{:ok, tasks}` where `tasks` is a list of normalized task maps.
  The `taskId` format is build-system-specific (Turbo uses `#`, Nx uses `:`):

      %{
        "taskId" => "package#task",   # or "package:task" for Nx
        "task" => "build",
        "package" => "mylib",
        "hash" => "abc123",           # may be "" if unavailable (e.g. Nx)
        "command" => "vite build",    # may be "" if unavailable (e.g. Nx)
        "dependencies" => ["core#build"],
        "dependents" => ["app#build"],
        "cache" => %{"status" => "MISS"}
      }
  """
  @callback parse_graph(json :: String.t()) ::
              {:ok, [map()]} | {:error, String.t()}

  @doc """
  Return the command to execute a single task.

  Returns `{executable, args}` to be used with `Port.open/2`.
  """
  @callback task_command(work_dir :: String.t(), package :: String.t(), task :: String.t()) ::
              {executable :: String.t(), args :: [String.t()]}

  @doc "Resolve a build system name to its adapter module."
  def resolve("turbo"), do: {:ok, DxCore.Agents.BuildSystem.Turbo}
  def resolve("nx"), do: {:ok, DxCore.Agents.BuildSystem.Nx}
  def resolve("generic"), do: {:ok, DxCore.Agents.BuildSystem.Generic}
  def resolve("docker"), do: {:ok, DxCore.Agents.BuildSystem.Docker}
  def resolve(other), do: {:error, "Unknown build system: #{other}"}
end
