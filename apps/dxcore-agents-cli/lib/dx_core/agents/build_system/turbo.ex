defmodule DxCore.Agents.BuildSystem.Turbo do
  @moduledoc "Turborepo build system adapter."

  @behaviour DxCore.Agents.BuildSystem

  @impl true
  def parse_graph(json) do
    case Jason.decode(json) do
      {:ok, %{"tasks" => tasks}} when is_list(tasks) ->
        {dropped, kept} = Enum.split_with(tasks, &nonexistent_task?/1)
        dropped = Map.new(dropped, &{&1["taskId"], &1})

        tasks =
          kept
          |> Enum.map(&contract_edges(&1, dropped))
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
    |> Map.put(
      "command",
      # Off a TTY (every dxcore agent run), turbo's own --log-order=auto
      # resolves to "grouped", holding a task's whole output until it ends.
      # --log-order=stream prints each line as turbo receives it, still
      # prefixed with <package>:<task>, so a hung dependency is visible
      # instead of silent for the task's whole run (#11867, #11876).
      "npx turbo run #{task["task"]} --filter=#{task["package"]} --log-order=stream"
    )
  end

  defp nonexistent_task?(%{"command" => "<NONEXISTENT>"}), do: true
  defp nonexistent_task?(_), do: false

  # A dropped <NONEXISTENT> task is a no-op (no package script), so it is not
  # dispatched (#4154). Its edges still order the graph: `test` reaches its own
  # package's `build` only through `test:binary`, which has no script. So each
  # dropped id in a survivor's `dependencies` becomes that task's own
  # dependencies, and in `dependents` its dependents, through chains of
  # dropped tasks. Pruning the id alone let every test part start at once and
  # compile `build` itself in parallel (#15603).
  defp contract_edges(task, dropped) do
    Enum.reduce(["dependencies", "dependents"], task, fn key, acc ->
      case acc[key] do
        ids when is_list(ids) -> Map.put(acc, key, expand(ids, key, dropped, MapSet.new()))
        _ -> acc
      end
    end)
  end

  # `seen` holds the dropped ids already expanded on this path, so a cycle
  # among dropped tasks ends.
  defp expand(ids, key, dropped, seen) do
    ids
    |> Enum.flat_map(fn id ->
      case dropped do
        %{^id => gap} ->
          if MapSet.member?(seen, id),
            do: [],
            else: expand(List.wrap(gap[key]), key, dropped, MapSet.put(seen, id))

        _ ->
          [id]
      end
    end)
    |> Enum.uniq()
  end

  # Read cacheable from resolvedTaskDefinition.cache (Turbo dry-run JSON).
  # Defaults to true since Turbo tasks are cacheable unless explicitly disabled.
  defp resolve_cacheable(%{"resolvedTaskDefinition" => %{"cache" => cache}})
       when is_boolean(cache),
       do: cache

  defp resolve_cacheable(_), do: true
end
