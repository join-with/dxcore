defmodule DxCore.Agents.BuildSystem.Gradle do
  @moduledoc """
  Gradle build system adapter.

  Parses the JSON output of the DxCore Gradle plugin (`exportDxcoreGraph` task),
  which emits all tasks reachable from each subproject's `build` goal with a
  `cacheable` boolean flag based on `@CacheableTask` annotation detection.

  The `hash` field defaults to `""` and `cache` is always `MISS` since Gradle's
  build cache is managed externally (not by DxCore).
  """

  @behaviour DxCore.Agents.BuildSystem

  alias DxCore.Agents.BuildSystem.GraphHelpers

  @required_fields ~w(taskId package task command)

  @impl true
  def parse_graph(json) do
    case Jason.decode(json) do
      {:ok, %{"tasks" => tasks}} when is_list(tasks) ->
        normalize_tasks(tasks)

      {:ok, _} ->
        {:error, "Unexpected Gradle graph: missing tasks key"}

      {:error, reason} ->
        {:error, "Failed to parse Gradle graph JSON: #{Exception.message(reason)}"}
    end
  end

  @impl true
  def task_command(work_dir, package, task) do
    gradlew = Path.join(work_dir, "gradlew")
    {gradlew, [":#{package}:#{task}"]}
  end

  defp normalize_tasks(tasks) do
    case Enum.find(tasks, &missing_field?/1) do
      nil ->
        deps_index = Map.new(tasks, fn t -> {t["taskId"], t["dependencies"] || []} end)
        dependents_map = GraphHelpers.invert_dependencies(deps_index)

        normalized =
          Enum.map(tasks, fn task -> normalize_task(task, deps_index, dependents_map) end)

        {:ok, normalized}

      bad_task ->
        missing = Enum.find(@required_fields, fn f -> not Map.has_key?(bad_task, f) end)
        {:error, "Task missing required field: #{missing}"}
    end
  end

  defp missing_field?(task) do
    Enum.any?(@required_fields, fn f -> not Map.has_key?(task, f) end)
  end

  defp normalize_task(task, deps_index, dependents_map) do
    id = task["taskId"]

    %{
      "taskId" => id,
      "task" => task["task"],
      "package" => task["package"],
      "command" => task["command"],
      "cacheable" => Map.get(task, "cacheable", true),
      "hash" => "",
      "dependencies" => Map.get(deps_index, id, []),
      "dependents" => Map.get(dependents_map, id, []),
      "cache" => %{"status" => "MISS"}
    }
  end
end
