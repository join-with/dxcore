defmodule DxCore.Agents.BuildSystem.GraphHelpers do
  @moduledoc "Shared graph utility functions for build system adapters."

  @doc "Invert a dependency index to produce a dependents map."
  def invert_dependencies(deps_index) do
    Enum.reduce(deps_index, %{}, fn {task_id, dep_ids}, acc ->
      acc = Map.put_new(acc, task_id, [])

      Enum.reduce(dep_ids, acc, fn dep_id, inner_acc ->
        Map.update(inner_acc, dep_id, [task_id], &[task_id | &1])
      end)
    end)
  end

  @doc "Ensure a named ETS table exists, creating it if needed. Race-safe."
  def ensure_ets_table(table_name) do
    case :ets.whereis(table_name) do
      :undefined ->
        try do
          :ets.new(table_name, [:named_table, :public, :set])
        rescue
          ArgumentError -> table_name
        end

      _ ->
        table_name
    end
  end
end
