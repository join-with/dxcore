defmodule DxCore.Agents.BuildSystem.Nx do
  @moduledoc """
  Nx build system adapter.

  Parses `nx run-many --graph=stdout` JSON output. Note: Nx does not provide task
  hashes or cache-hit status at plan time, so `hash` defaults to `""` and `cache`
  is always `MISS`.
  """

  @behaviour DxCore.Agents.BuildSystem

  alias DxCore.Agents.BuildSystem.GraphHelpers

  @impl true
  def parse_graph(json) do
    case Jason.decode(json) do
      {:ok, %{"tasks" => %{"tasks" => tasks_map, "dependencies" => deps_map}}} ->
        dependents_map = GraphHelpers.invert_dependencies(deps_map)

        tasks =
          tasks_map
          |> Enum.map(fn {_id, task} -> normalize_task(task, deps_map, dependents_map) end)

        {:ok, tasks}

      {:ok, _} ->
        {:error, "Unexpected Nx graph output: missing tasks field"}

      {:error, reason} ->
        {:error, "Failed to parse Nx graph JSON: #{Exception.message(reason)}"}
    end
  end

  defp normalize_task(task, deps_map, dependents_map) do
    id = task["id"]
    package = get_in(task, ["target", "project"])
    target = get_in(task, ["target", "target"])

    %{
      "taskId" => id,
      "task" => target,
      "package" => package,
      "hash" => task["hash"] || "",
      "command" => "npx nx run #{package}:#{target}",
      "cacheable" => Map.get(task, "cache", false),
      "dependencies" => Map.get(deps_map, id, []),
      "dependents" => Map.get(dependents_map, id, []),
      "cache" => %{"status" => "MISS"}
    }
  end
end
