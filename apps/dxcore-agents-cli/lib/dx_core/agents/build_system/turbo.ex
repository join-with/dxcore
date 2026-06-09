defmodule DxCore.Agents.BuildSystem.Turbo do
  @moduledoc "Turborepo build system adapter."

  @behaviour DxCore.Agents.BuildSystem

  @impl true
  def parse_graph(json) do
    case Jason.decode(json) do
      {:ok, %{"tasks" => tasks}} when is_list(tasks) ->
        tasks =
          tasks
          |> Enum.reject(&nonexistent_task?/1)
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

  # Read cacheable from resolvedTaskDefinition.cache (Turbo dry-run JSON).
  # Defaults to true since Turbo tasks are cacheable unless explicitly disabled.
  defp resolve_cacheable(%{"resolvedTaskDefinition" => %{"cache" => cache}})
       when is_boolean(cache),
       do: cache

  defp resolve_cacheable(_), do: true
end
