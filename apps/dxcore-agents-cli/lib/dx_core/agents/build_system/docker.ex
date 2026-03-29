defmodule DxCore.Agents.BuildSystem.Docker do
  @moduledoc """
  Docker Buildx Bake build system adapter.

  Parses the output of `docker buildx bake --print`, which outputs JSON
  describing all build targets with their Dockerfiles, contexts, tags,
  and cross-target dependencies via the `contexts` field.

  Each target in the bake file becomes a task with `task="build"` and
  `package=<target name>`. Dependencies are extracted from the `contexts`
  map where values start with `"target:"`.

  Target metadata is stored in ETS table `:dxcore_docker_targets` keyed
  by target name for lookup by `task_command/3`.
  """

  @behaviour DxCore.Agents.BuildSystem

  alias DxCore.Agents.BuildSystem.GraphHelpers

  @ets_table :dxcore_docker_targets

  @impl true
  def parse_graph(json) do
    case Jason.decode(json) do
      {:ok, %{"target" => targets}} when is_map(targets) ->
        normalized = normalize_targets(targets)
        store_targets(normalized, targets)
        {:ok, normalized}

      {:ok, _} ->
        {:error, "Unexpected Docker bake output: missing target key"}

      {:error, reason} ->
        {:error, "Failed to parse Docker bake JSON: #{Exception.message(reason)}"}
    end
  end

  @impl true
  def task_command(_work_dir, package, _task) do
    target =
      case :ets.lookup(@ets_table, package) do
        [{_key, meta}] -> meta
        [] -> raise "No Docker target found for #{package} — call parse_graph/1 first"
      end

    dockerfile = target["dockerfile"]
    context = target["context"]
    tags = target["tags"] || []

    tag_args = Enum.flat_map(tags, fn tag -> ["-t", tag] end)

    args = ["buildx", "build", "-f", dockerfile] ++ tag_args ++ ["--push", context]

    docker = System.find_executable("docker") || "docker"
    {docker, args}
  end

  defp normalize_targets(targets) do
    deps_index = Map.new(targets, fn {name, meta} -> {name, extract_deps(meta)} end)
    dependents_map = GraphHelpers.invert_dependencies(deps_index)

    Enum.map(targets, fn {name, _meta} ->
      %{
        "taskId" => name,
        "task" => "build",
        "package" => name,
        "hash" => "",
        "command" => "",
        "dependencies" => Map.get(deps_index, name, []),
        "dependents" => Map.get(dependents_map, name, []),
        "cache" => %{"status" => "MISS"}
      }
    end)
  end

  defp extract_deps(meta) do
    contexts = Map.get(meta, "contexts", %{})

    contexts
    |> Map.values()
    |> Enum.filter(&String.starts_with?(&1, "target:"))
    |> Enum.map(&String.replace_prefix(&1, "target:", ""))
  end

  defp store_targets(normalized_tasks, raw_targets) do
    GraphHelpers.ensure_ets_table(@ets_table)
    :ets.delete_all_objects(@ets_table)

    Enum.each(normalized_tasks, fn task ->
      name = task["package"]
      :ets.insert(@ets_table, {name, Map.get(raw_targets, name, %{})})
    end)
  end
end
