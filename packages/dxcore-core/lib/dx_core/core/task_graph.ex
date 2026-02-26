defmodule DxCore.Core.TaskGraph do
  @moduledoc "Parses normalized task graph JSON into a task dependency graph."

  @type t :: %__MODULE__{tasks: %{String.t() => Task.t()}}

  defstruct [:tasks]

  defmodule Task do
    @moduledoc false

    @type t :: %__MODULE__{
            task_id: String.t() | nil,
            task: String.t() | nil,
            package: String.t() | nil,
            hash: String.t() | nil,
            command: String.t() | nil,
            deps: [String.t()],
            dependents: [String.t()],
            cache_status: :hit | :miss,
            shard: map() | nil
          }

    defstruct [
      :task_id,
      :task,
      :package,
      :hash,
      :command,
      :deps,
      :dependents,
      :cache_status,
      :shard
    ]
  end

  @doc """
  Parses a normalized task list JSON string into a `%TaskGraph{}`.

  Returns `{:ok, %TaskGraph{}}` on success, or `{:error, reason}` on failure.
  """
  def parse(json_string) do
    case Jason.decode(json_string) do
      {:ok, %{"tasks" => raw_tasks}} ->
        tasks = raw_tasks |> Enum.map(&parse_task/1) |> Map.new(fn t -> {t.task_id, t} end)
        {:ok, %__MODULE__{tasks: tasks}}

      {:ok, _} ->
        {:error, :missing_tasks_key}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Parses a shard descriptor into `%{index: integer, count: integer}`.

  Accepts:
  - `nil` → `nil`
  - `%{"index" => i, "count" => c}` (decoded JSON map) → `%{index: i, count: c}`
  - `"1/4"` (string shorthand) → `%{index: 1, count: 4}`
  - anything else → `nil`
  """
  def parse_shard(nil), do: nil

  def parse_shard(%{"index" => index, "count" => count})
      when is_integer(index) and is_integer(count) do
    %{index: index, count: count}
  end

  def parse_shard(shard_string) when is_binary(shard_string) do
    case String.split(shard_string, "/") do
      [index_str, count_str] ->
        with {index, ""} <- Integer.parse(index_str),
             {count, ""} <- Integer.parse(count_str) do
          %{index: index, count: count}
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end

  def parse_shard(_), do: nil

  defp parse_task(raw) do
    %Task{
      task_id: raw["taskId"],
      task: raw["task"],
      package: raw["package"],
      hash: raw["hash"],
      command: raw["command"],
      deps: raw["dependencies"] || [],
      dependents: raw["dependents"] || [],
      cache_status: parse_cache_status(raw),
      shard: parse_shard(raw["shard"])
    }
  end

  defp parse_cache_status(%{"cache" => %{"status" => "HIT"}}), do: :hit
  defp parse_cache_status(_), do: :miss

  @doc """
  Returns the initial frontier: tasks that are ready to execute.

  A task is in the initial frontier when:
  - It is not a cache hit (cache hits are already done), AND
  - All of its dependencies are cache hits (i.e., already satisfied).

  Tasks with no dependencies and a MISS cache status are also in the frontier.
  """
  def initial_frontier(%__MODULE__{tasks: tasks}) do
    done_tasks =
      tasks
      |> Enum.filter(fn {_id, task} -> task.cache_status == :hit end)
      |> MapSet.new(fn {id, _task} -> id end)

    tasks
    |> Enum.filter(fn {_id, task} ->
      task.cache_status != :hit and
        Enum.all?(task.deps, fn dep -> MapSet.member?(done_tasks, dep) end)
    end)
    |> MapSet.new(fn {id, _task} -> id end)
  end
end
