defmodule DxCore.Agents.ShardConfig do
  @moduledoc """
  Scans a repository for `dxcore.json` files and merges them into a unified
  shard configuration map keyed by `"package#task"`.

  Each `dxcore.json` lives in a package directory and may contain a `shards` key:

      # apps/e2e-app/dxcore.json
      {"shards": {"test": 4}}

  The package name is derived from the parent directory name.
  """

  require Logger

  @doc """
  Scans `base_dir` for all `**/dxcore.json` files and returns a merged map
  of `%{"package#task" => shard_count}`.

  - Skips files with invalid JSON (logs a warning)
  - Skips files without a `shards` key
  - Filters out non-integer or non-positive shard values
  """
  @spec scan(String.t()) :: %{String.t() => pos_integer()}
  def scan(base_dir) do
    pattern = Path.join(base_dir, "**/dxcore.json")

    pattern
    |> Path.wildcard()
    |> Enum.reduce(%{}, fn file_path, acc ->
      case parse_file(file_path) do
        {:ok, entries} -> Map.merge(acc, entries)
        :skip -> acc
      end
    end)
  end

  @doc """
  Formats a shard config map as a sorted list of human-readable strings.

  ## Examples

      iex> ShardConfig.format_summary(%{"e2e-app#test" => 4, "web-app#test" => 2})
      ["e2e-app#test: 4 shards", "web-app#test: 2 shards"]

      iex> ShardConfig.format_summary(%{})
      []

  """
  @spec format_summary(%{String.t() => pos_integer()}) :: [String.t()]
  def format_summary(config) when map_size(config) == 0, do: []

  def format_summary(config) do
    config
    |> Enum.sort_by(fn {key, _} -> key end)
    |> Enum.map(fn {key, count} -> "#{key}: #{count} shards" end)
  end

  # --- Private ---

  defp parse_file(file_path) do
    package_name = file_path |> Path.dirname() |> Path.basename()

    case File.read(file_path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, %{"shards" => shards}} when is_map(shards) ->
            entries =
              shards
              |> Enum.filter(fn {_task, count} -> is_integer(count) and count > 0 end)
              |> Enum.into(%{}, fn {task, count} -> {"#{package_name}##{task}", count} end)

            {:ok, entries}

          {:ok, _data} ->
            :skip

          {:error, reason} ->
            Logger.warning(
              "[ShardConfig] Skipping #{file_path}: invalid JSON (#{Exception.message(reason)})"
            )

            :skip
        end

      {:error, reason} ->
        Logger.warning("[ShardConfig] Could not read #{file_path}: #{:file.format_error(reason)}")

        :skip
    end
  end
end
