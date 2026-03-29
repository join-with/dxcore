defmodule DxCore.Agents.BuildSystem.Generic do
  @moduledoc """
  Generic JSON build system adapter.

  Accepts a task DAG in DxCore's own JSON format with explicit commands per task.
  This is the "escape hatch" adapter for any build system that can be described
  as a DAG with explicit shell commands.

  Expected JSON format:

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

  The `hash` field defaults to `""` and `cache` is always `MISS`.
  Commands are stored in ETS keyed by `{package, task}` for lookup by `task_command/3`.
  """

  @behaviour DxCore.Agents.BuildSystem

  alias DxCore.Agents.BuildSystem.GraphHelpers

  @ets_table :dxcore_generic_commands
  @required_fields ~w(taskId package task command)

  @impl true
  def parse_graph(json) do
    case Jason.decode(json) do
      {:ok, %{"tasks" => tasks}} when is_list(tasks) ->
        with {:ok, normalized} <- normalize_tasks(tasks) do
          store_commands(normalized)
          {:ok, normalized}
        end

      {:ok, _} ->
        {:error, "Unexpected Generic graph: missing tasks key"}

      {:error, reason} ->
        {:error, "Failed to parse Generic graph JSON: #{Exception.message(reason)}"}
    end
  end

  @impl true
  def task_command(_work_dir, package, task) do
    command =
      case :ets.lookup(@ets_table, {package, task}) do
        [{_key, cmd}] -> cmd
        [] -> raise "No command found for #{package}:#{task} — call parse_graph/1 first"
      end

    [executable | args] = String.split(command)
    resolved = System.find_executable(executable) || executable
    {resolved, args}
  end

  defp normalize_tasks(tasks) do
    validation_result =
      Enum.reduce_while(tasks, :ok, fn task, :ok ->
        case validate_task(task) do
          :ok -> {:cont, :ok}
          {:error, _} = err -> {:halt, err}
        end
      end)

    with :ok <- validation_result do
      deps_index = Map.new(tasks, fn t -> {t["taskId"], t["dependencies"] || []} end)
      dependents_map = GraphHelpers.invert_dependencies(deps_index)

      normalized =
        Enum.map(tasks, fn task -> normalize_task(task, deps_index, dependents_map) end)

      {:ok, normalized}
    end
  end

  defp validate_task(task) do
    missing = Enum.find(@required_fields, fn field -> not Map.has_key?(task, field) end)

    if missing do
      {:error, "Task missing required field: #{missing}"}
    else
      :ok
    end
  end

  defp normalize_task(task, deps_index, dependents_map) do
    id = task["taskId"]

    %{
      "taskId" => id,
      "task" => task["task"],
      "package" => task["package"],
      "command" => task["command"],
      "hash" => "",
      "dependencies" => Map.get(deps_index, id, []),
      "dependents" => Map.get(dependents_map, id, []),
      "cache" => %{"status" => "MISS"}
    }
  end

  defp store_commands(tasks) do
    GraphHelpers.ensure_ets_table(@ets_table)
    :ets.delete_all_objects(@ets_table)

    Enum.each(tasks, fn task ->
      :ets.insert(@ets_table, {{task["package"], task["task"]}, task["command"]})
    end)
  end
end
