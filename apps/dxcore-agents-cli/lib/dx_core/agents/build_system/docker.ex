defmodule DxCore.Agents.BuildSystem.Docker do
  @moduledoc """
  Docker Buildx Bake build system adapter.

  Parses the output of `docker buildx bake --print`, which outputs JSON
  describing all build targets with their Dockerfiles, contexts, tags,
  and cross-target dependencies via the `contexts` field.

  Each target in the bake file becomes a task with `task="build"` and
  `package=<target name>`. Dependencies are extracted from the `contexts`
  map where values start with `"target:"`.

  The full `docker buildx build` command is constructed during graph parsing
  and stored in the `command` field so the coordinator can forward it to agents.
  Targets with `cache-from` or `cache-to` configured are marked `cacheable: true`.
  """

  @behaviour DxCore.Agents.BuildSystem

  alias DxCore.Agents.BuildSystem.GraphHelpers

  @impl true
  def parse_graph(json) do
    case Jason.decode(json) do
      {:ok, %{"target" => targets}} when is_map(targets) ->
        {:ok, normalize_targets(targets)}

      {:ok, _} ->
        {:error, "Unexpected Docker bake output: missing target key"}

      {:error, reason} ->
        {:error, "Failed to parse Docker bake JSON: #{Exception.message(reason)}"}
    end
  end

  defp normalize_targets(targets) do
    deps_index = Map.new(targets, fn {name, meta} -> {name, extract_deps(meta)} end)
    dependents_map = GraphHelpers.invert_dependencies(deps_index)

    Enum.map(targets, fn {name, meta} ->
      %{
        "taskId" => name,
        "task" => "build",
        "package" => name,
        "hash" => "",
        "command" => build_command(meta),
        "cacheable" => has_remote_cache?(meta),
        "dependencies" => Map.get(deps_index, name, []),
        "dependents" => Map.get(dependents_map, name, []),
        "cache" => %{"status" => "MISS"}
      }
    end)
  end

  defp build_command(meta) do
    dockerfile = meta["dockerfile"]
    context = meta["context"]
    tags = meta["tags"] || []

    tag_args = Enum.flat_map(tags, fn tag -> ["-t", tag] end)
    args = ["docker", "buildx", "build", "-f", dockerfile] ++ tag_args ++ ["--push", context]
    Enum.join(args, " ")
  end

  # A target is cacheable if it has cache-from or cache-to configured,
  # indicating remote cache sharing between agents.
  defp has_remote_cache?(meta) do
    has_entries?(meta["cache-from"]) or has_entries?(meta["cache-to"])
  end

  defp has_entries?([_ | _]), do: true
  defp has_entries?(_), do: false

  defp extract_deps(meta) do
    contexts = Map.get(meta, "contexts", %{})

    contexts
    |> Map.values()
    |> Enum.filter(&String.starts_with?(&1, "target:"))
    |> Enum.map(&String.replace_prefix(&1, "target:", ""))
  end
end
