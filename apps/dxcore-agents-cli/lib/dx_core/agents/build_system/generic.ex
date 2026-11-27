defmodule DxCore.Agents.BuildSystem.Generic do
  @moduledoc """
  DxCore's own task graph: the format the coordinator validates
  (`DxCore.Core.TaskGraph.parse/1`), sent as it is.

  Any build system that can be described as a DAG with explicit shell
  commands writes it; a turbo dry run is converted to it by
  `@repo/dxcore-turbo-graph` (`node packages/dxcore-turbo-graph/bin/dxcore-turbo-graph.mjs`).

      {
        "tasks": [
          {
            "taskId": "migrate",
            "package": "db",
            "task": "migrate",
            "command": "mix ecto.migrate",
            "dependencies": []
          }
        ]
      }

  A task carries only the agent protocol's `taskFields`
  (@repo/dxcore-contract's agent-protocol.json); `taskId`, `package`, `task`
  and `command` are required, a missing `hash` is `""`, a missing
  `dependencies` none and a missing `cache` a `MISS`. The coordinator refuses
  any other field.
  """

  @behaviour DxCore.Agents.BuildSystem

  @required_fields ~w(taskId package task command)

  @impl true
  def parse_graph(json) do
    case Jason.decode(json) do
      {:ok, %{"tasks" => tasks}} when is_list(tasks) ->
        normalize_tasks(tasks)

      {:ok, _} ->
        {:error, "Unexpected Generic graph: missing tasks key"}

      {:error, reason} ->
        {:error, "Failed to parse Generic graph JSON: #{Exception.message(reason)}"}
    end
  end

  defp normalize_tasks(tasks) do
    case Enum.find_value(tasks, &missing_field/1) do
      nil -> {:ok, Enum.map(tasks, &normalize_task/1)}
      error -> error
    end
  end

  defp missing_field(task) when is_map(task) do
    case Enum.find(@required_fields, &(not Map.has_key?(task, &1))) do
      nil -> nil
      field -> {:error, "Task missing required field: #{field}"}
    end
  end

  defp missing_field(_task), do: {:error, "A task is not an object"}

  defp normalize_task(task) do
    task
    |> Map.put_new("hash", "")
    |> Map.put_new("dependencies", [])
    |> Map.put_new("cache", %{"status" => "MISS"})
  end
end
