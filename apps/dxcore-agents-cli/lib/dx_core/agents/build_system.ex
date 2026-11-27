defmodule DxCore.Agents.BuildSystem do
  @moduledoc """
  Behaviour for build system adapters.

  Each adapter normalizes a build system's task graph JSON into dxcore's own
  format (`DxCore.Agents.BuildSystem.Generic` describes it), which the
  coordinator validates and never converts. The `command` field must be populated
  during `parse_graph/1` — the coordinator forwards it to agents for execution.
  """

  @doc """
  Parse a build system's JSON output into normalized task maps.

  Accepts the raw JSON string from the build system's introspection command
  (e.g. `nx run-many --graph=stdout`, or dxcore's own graph).

  Returns `{:ok, tasks}` where `tasks` is a list of normalized task maps.
  The `taskId` format is build-system-specific (Nx uses `project:target`):

      %{
        "taskId" => "mylib:build",
        "task" => "build",
        "package" => "mylib",
        "hash" => "",                 # "" when the build system has none
        "command" => "npx nx run mylib:build",
        "dependencies" => ["core:build"],
        "cache" => %{"status" => "MISS"}
      }
  """
  @callback parse_graph(json :: String.t()) ::
              {:ok, [map()]} | {:error, String.t()}

  @doc "Resolve a build system name to its adapter module."
  def resolve("turbo"),
    do:
      {:error,
       "A turbo dry run is converted to dxcore's graph first: " <>
         "turbo run <tasks> --dry=json | node packages/dxcore-turbo-graph/bin/dxcore-turbo-graph.mjs | " <>
         "dxcore dispatch --build-system=generic ..."}

  def resolve("nx"), do: {:ok, DxCore.Agents.BuildSystem.Nx}
  def resolve("generic"), do: {:ok, DxCore.Agents.BuildSystem.Generic}
  def resolve("docker"), do: {:ok, DxCore.Agents.BuildSystem.Docker}
  def resolve("gradle"), do: {:ok, DxCore.Agents.BuildSystem.Gradle}
  def resolve(other), do: {:error, "Unknown build system: #{other}"}
end
