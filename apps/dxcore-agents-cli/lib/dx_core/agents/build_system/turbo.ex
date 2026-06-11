defmodule DxCore.Agents.BuildSystem.Turbo do
  @moduledoc "Turborepo build system adapter."

  @behaviour DxCore.Agents.BuildSystem

  @impl true
  def parse_graph(json) do
    case Jason.decode(json) do
      {:ok, %{"tasks" => tasks}} when is_list(tasks) ->
        {dropped, kept} = Enum.split_with(tasks, &nonexistent_task?/1)
        dropped_ids = MapSet.new(dropped, & &1["taskId"])

        tasks =
          kept
          |> Enum.map(&prune_dependencies(&1, dropped_ids))
          |> Enum.map(&normalize_task/1)

        {:ok, tasks}

      {:ok, _} ->
        {:error, "Unexpected turbo output: missing tasks key"}

      {:error, reason} ->
        {:error, "Failed to parse turbo JSON output: #{Exception.message(reason)}"}
    end
  end

  defp normalize_task(task) do
    task
    |> Map.put("cacheable", resolve_cacheable(task))
    |> Map.put("command", "npx turbo run #{task["task"]} --filter=#{task["package"]}")
  end

  defp nonexistent_task?(%{"command" => "<NONEXISTENT>"}), do: true
  defp nonexistent_task?(_), do: false

  # A dropped <NONEXISTENT> task is a no-op (no package script) — logically it is
  # already done. Remove its id from surviving tasks' dependency lists so the
  # coordinator doesn't see a dependency on a task absent from the graph and
  # block the dependent forever. See #4154.
  defp prune_dependencies(task, dropped_ids) do
    case task["dependencies"] do
      deps when is_list(deps) ->
        Map.put(task, "dependencies", Enum.reject(deps, &MapSet.member?(dropped_ids, &1)))

      _ ->
        task
    end
  end

  # Read cacheable from resolvedTaskDefinition.cache (Turbo dry-run JSON).
  # Defaults to true since Turbo tasks are cacheable unless explicitly disabled.
  defp resolve_cacheable(%{"resolvedTaskDefinition" => %{"cache" => cache}})
       when is_boolean(cache),
       do: cache

  defp resolve_cacheable(_), do: true
end
