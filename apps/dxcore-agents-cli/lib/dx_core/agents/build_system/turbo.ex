defmodule DxCore.Agents.BuildSystem.Turbo do
  @moduledoc "Turborepo build system adapter."

  @behaviour DxCore.Agents.BuildSystem

  @impl true
  def parse_graph(json) do
    case Jason.decode(json) do
      {:ok, %{"tasks" => tasks}} when is_list(tasks) ->
        {:ok, tasks}

      {:ok, _} ->
        {:error, "Unexpected turbo output: missing tasks key"}

      {:error, reason} ->
        {:error, "Failed to parse turbo JSON output: #{Exception.message(reason)}"}
    end
  end

  @impl true
  def task_command(_work_dir, package, task) do
    npx = System.find_executable("npx") || raise "npx not found in PATH"
    {npx, ["turbo", "run", task, "--filter=#{package}"]}
  end
end
