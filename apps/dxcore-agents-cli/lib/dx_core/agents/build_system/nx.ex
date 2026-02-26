defmodule DxCore.Agents.BuildSystem.Nx do
  @moduledoc """
  Nx build system adapter.

  Parses `nx run-many --graph=stdout` JSON output. Note: Nx does not provide task
  hashes or cache-hit status at plan time, so `hash` defaults to `""` and `cache`
  is always `MISS`.
  """

  @behaviour DxCore.Agents.BuildSystem

  @impl true
  def parse_graph(json) do
    case Jason.decode(json) do
      {:ok, %{"tasks" => %{"tasks" => tasks_map, "dependencies" => deps_map}}} ->
        dependents_map = invert_dependencies(deps_map)

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

  @impl true
  def task_command(_work_dir, package, task) do
    npx = System.find_executable("npx") || raise "npx not found in PATH"
    {npx, ["nx", "run", "#{package}:#{task}"]}
  end

  defp normalize_task(task, deps_map, dependents_map) do
    id = task["id"]

    %{
      "taskId" => id,
      "task" => get_in(task, ["target", "target"]),
      "package" => get_in(task, ["target", "project"]),
      "hash" => task["hash"] || "",
      "command" => "",
      "dependencies" => Map.get(deps_map, id, []),
      "dependents" => Map.get(dependents_map, id, []),
      "cache" => %{"status" => "MISS"}
    }
  end

  defp invert_dependencies(deps_map) do
    Enum.reduce(deps_map, %{}, fn {task_id, dep_ids}, acc ->
      Enum.reduce(dep_ids, acc, fn dep_id, inner_acc ->
        Map.update(inner_acc, dep_id, [task_id], &[task_id | &1])
      end)
    end)
  end
end
