defmodule DxCore.Core.TaskGraph do
  @moduledoc "Validates dxcore's task graph JSON and parses it into a task dependency graph."

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
            cacheable: boolean(),
            shard: map() | nil,
            requirements: map()
          }

    defstruct [
      :task_id,
      :task,
      :package,
      :hash,
      :command,
      :cache_status,
      :shard,
      deps: [],
      dependents: [],
      cacheable: false,
      requirements: %{}
    ]
  end

  # The fields a task may carry, and nothing else: @repo/dxcore-contract's
  # `taskFields` (agent-protocol.json), which AgentProtocolContractTest keeps
  # equal to what `parse_task/1` reads. `dependents` is not one: it is
  # derived here from every task's `dependencies`.
  @fields ~w(taskId task package hash command dependencies cache cacheable shard requirements)

  # What a graph may hold. PR #19394's affected run, converted, has 2,666
  # tasks and 4,839 edges in about 1 MB.
  @max_tasks 20_000
  @max_edges 400_000
  @max_dependencies 5_000
  @max_string_bytes 1_024
  @max_command_bytes 8_192
  @max_requirements 32

  @doc "The fields a task may carry."
  @spec fields() :: [String.t()]
  def fields, do: @fields

  @doc """
  Parses dxcore's task graph JSON, `{"tasks": [...]}`, into a `%TaskGraph{}`.
  It converts nothing; it refuses a graph that is not exactly that format,
  with one message naming the first problem:

    * every task is an object with only the `fields/0`, and a `taskId`;
    * `taskId`, `task`, `package`, `hash` are strings of at most
      #{@max_string_bytes} bytes (`taskId`, `task`, `package` not empty),
      `command` a non-empty one of at most #{@max_command_bytes};
    * `dependencies` lists distinct ids of tasks in the graph, at most
      #{@max_dependencies}, and the graph has no cycle;
    * `cache` is `{"status": "HIT" | "MISS"}`, `cacheable` a boolean,
      `shard` null, `{"index", "count"}` integers or `"i/n"`, and
      `requirements` at most #{@max_requirements} string keys with string
      values of at most #{@max_string_bytes} bytes;
    * at most #{@max_tasks} tasks, unique ids, and #{@max_edges} edges.

  Other top-level keys (the DTE graph's `fit`) are the caller's.
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, String.t()}
  def parse(json_string) when is_binary(json_string) do
    case Jason.decode(json_string) do
      {:ok, %{"tasks" => raw_tasks}} when is_list(raw_tasks) ->
        with :ok <- check_graph(raw_tasks) do
          {:ok, %__MODULE__{tasks: build(raw_tasks)}}
        end

      {:ok, _} ->
        {:error, "the graph has no tasks list"}

      {:error, error} ->
        {:error, "the graph is not JSON: #{Exception.message(error)}"}
    end
  end

  defp build(raw_tasks) do
    tasks = Map.new(raw_tasks, fn raw -> {raw["taskId"], parse_task(raw)} end)

    dependents =
      Enum.reduce(raw_tasks, %{}, fn raw, acc ->
        Enum.reduce(raw["dependencies"] || [], acc, fn dep, acc ->
          Map.update(acc, dep, [raw["taskId"]], &[raw["taskId"] | &1])
        end)
      end)

    Map.new(tasks, fn {id, task} ->
      {id, %{task | dependents: dependents |> Map.get(id, []) |> Enum.reverse()}}
    end)
  end

  defp check_graph(raw_tasks) do
    cond do
      length(raw_tasks) > @max_tasks ->
        {:error, "the graph has #{length(raw_tasks)} tasks, over the cap of #{@max_tasks}"}

      true ->
        with :ok <- each(raw_tasks, &check_task/1),
             :ok <- check_ids(raw_tasks),
             :ok <- check_edges(raw_tasks) do
          check_acyclic(raw_tasks)
        end
    end
  end

  defp each(list, fun) do
    Enum.reduce_while(list, :ok, fn item, :ok ->
      case fun.(item) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp check_task(%{"taskId" => id} = raw) when is_binary(id) and id != "" do
    case Map.keys(raw) -- @fields do
      [] ->
        with :ok <- string(raw, "taskId", @max_string_bytes, :required),
             :ok <- string(raw, "task", @max_string_bytes, :required),
             :ok <- string(raw, "package", @max_string_bytes, :required),
             :ok <- string(raw, "hash", @max_string_bytes, :any),
             :ok <- string(raw, "command", @max_command_bytes, :required),
             :ok <- check_dependencies(id, raw["dependencies"]),
             :ok <- check_cache(id, raw),
             :ok <- check_cacheable(id, raw),
             :ok <- check_shard(id, raw),
             do: check_requirements(id, raw["requirements"])

      unknown ->
        {:error, "task #{id}: unknown fields #{Enum.join(Enum.sort(unknown), ", ")}"}
    end
  end

  defp check_task(%{"taskId" => _}), do: {:error, "a task's taskId is not a non-empty string"}
  defp check_task(raw) when is_map(raw), do: {:error, "a task has no taskId"}
  defp check_task(_), do: {:error, "a task is not an object"}

  # `:required` refuses a missing field or an empty string; `:any` (the hash)
  # takes either.
  defp string(raw, field, max, rule) do
    id = raw["taskId"]

    case Map.fetch(raw, field) do
      :error when rule == :required ->
        {:error, "task #{id}: no #{field}"}

      :error ->
        :ok

      {:ok, ""} when rule == :required ->
        {:error, "task #{id}: #{field} is empty"}

      {:ok, value} when is_binary(value) and byte_size(value) <= max ->
        :ok

      {:ok, value} when is_binary(value) ->
        {:error, "task #{id}: #{field} is #{byte_size(value)} bytes, over the cap of #{max}"}

      {:ok, _} ->
        {:error, "task #{id}: #{field} is not a string"}
    end
  end

  defp check_dependencies(_id, nil), do: :ok

  defp check_dependencies(id, deps) when is_list(deps) do
    cond do
      length(deps) > @max_dependencies ->
        {:error, "task #{id}: #{length(deps)} dependencies, over the cap of #{@max_dependencies}"}

      not Enum.all?(deps, &(is_binary(&1) and &1 != "")) ->
        {:error, "task #{id}: a dependency is not a non-empty string"}

      length(Enum.uniq(deps)) != length(deps) ->
        {:error, "task #{id}: lists a dependency twice"}

      true ->
        :ok
    end
  end

  defp check_dependencies(id, _), do: {:error, "task #{id}: dependencies is not a list"}

  defp check_cache(_id, raw) when not is_map_key(raw, "cache"), do: :ok

  defp check_cache(_id, %{"cache" => %{"status" => s} = c})
       when map_size(c) == 1 and s in ["HIT", "MISS"], do: :ok

  defp check_cache(id, _), do: {:error, ~s(task #{id}: cache is not {"status": "HIT" or "MISS"})}

  defp check_cacheable(_id, raw) when not is_map_key(raw, "cacheable"), do: :ok
  defp check_cacheable(_id, %{"cacheable" => c}) when is_boolean(c), do: :ok
  defp check_cacheable(id, _), do: {:error, "task #{id}: cacheable is not a boolean"}

  defp check_shard(_id, raw) when not is_map_key(raw, "shard"), do: :ok
  defp check_shard(_id, %{"shard" => nil}), do: :ok

  defp check_shard(id, %{"shard" => shard}) do
    if parse_shard(shard), do: :ok, else: {:error, "task #{id}: shard is not a shard"}
  end

  defp check_requirements(_id, nil), do: :ok

  defp check_requirements(id, reqs) when is_map(reqs) do
    cond do
      map_size(reqs) > @max_requirements ->
        {:error,
         "task #{id}: #{map_size(reqs)} requirements, over the cap of #{@max_requirements}"}

      not Enum.all?(reqs, fn {k, v} -> short?(k) and short?(v) end) ->
        {:error,
         "task #{id}: a requirement is not a string of at most #{@max_string_bytes} bytes"}

      true ->
        :ok
    end
  end

  defp check_requirements(id, _), do: {:error, "task #{id}: requirements is not an object"}

  defp short?(v), do: is_binary(v) and byte_size(v) <= @max_string_bytes

  defp check_ids(raw_tasks) do
    raw_tasks
    |> Enum.map(& &1["taskId"])
    |> Enum.frequencies()
    |> Enum.find(fn {_id, n} -> n > 1 end)
    |> case do
      nil -> :ok
      {id, _} -> {:error, "task #{id} is in the graph twice"}
    end
  end

  defp check_edges(raw_tasks) do
    ids = MapSet.new(raw_tasks, & &1["taskId"])
    edges = Enum.reduce(raw_tasks, 0, &(length(&1["dependencies"] || []) + &2))

    if edges > @max_edges do
      {:error, "the graph has #{edges} dependency edges, over the cap of #{@max_edges}"}
    else
      each(raw_tasks, fn raw ->
        case Enum.find(raw["dependencies"] || [], &(not MapSet.member?(ids, &1))) do
          nil -> :ok
          dep -> {:error, "task #{raw["taskId"]}: dependency #{dep} is not in the graph"}
        end
      end)
    end
  end

  # Kahn's algorithm: whatever is left once no task is ready is on a cycle
  # or waits for one.
  defp check_acyclic(raw_tasks) do
    waiting = Map.new(raw_tasks, &{&1["taskId"], length(&1["dependencies"] || [])})

    dependents =
      Enum.reduce(raw_tasks, %{}, fn raw, acc ->
        Enum.reduce(
          raw["dependencies"] || [],
          acc,
          &Map.update(&2, &1, [raw["taskId"]], fn l -> [raw["taskId"] | l] end)
        )
      end)

    ready = for {id, 0} <- waiting, do: id

    case peel(ready, waiting, dependents) do
      left when map_size(left) == 0 ->
        :ok

      left ->
        id = left |> Map.keys() |> Enum.min()

        {:error,
         "the graph has a cycle: #{map_size(left)} tasks never get ready, among them #{id}"}
    end
  end

  defp peel([], waiting, _dependents), do: waiting

  defp peel([id | rest], waiting, dependents) do
    {waiting, ready} =
      Enum.reduce(Map.get(dependents, id, []), {Map.delete(waiting, id), rest}, fn next, {w, r} ->
        case Map.fetch!(w, next) - 1 do
          0 -> {Map.put(w, next, 0), [next | r]}
          n -> {Map.put(w, next, n), r}
        end
      end)

    peel(ready, waiting, dependents)
  end

  @doc """
  Serializes a `%TaskGraph{}` into a JSON-compatible map matching the wire
  format consumed by `parse/1`. Used to persist the post-expansion graph for
  durability rehydration.
  """
  def serialize(%__MODULE__{tasks: tasks}) do
    %{
      "tasks" =>
        Enum.map(tasks, fn {_id, t} ->
          %{
            "taskId" => t.task_id,
            "task" => t.task,
            "package" => t.package,
            "hash" => t.hash,
            "command" => t.command,
            "dependencies" => t.deps,
            "cache" => %{"status" => if(t.cache_status == :hit, do: "HIT", else: "MISS")},
            "cacheable" => t.cacheable,
            "shard" => t.shard,
            "requirements" => t.requirements
          }
          # A field the task never had stays out, as `parse/1` refuses a
          # null string.
          |> Map.reject(fn {_field, value} -> is_nil(value) end)
        end)
    }
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
      cache_status: parse_cache_status(raw),
      cacheable: parse_cacheable(raw),
      shard: parse_shard(raw["shard"]),
      requirements: raw["requirements"] || %{}
    }
  end

  defp parse_cache_status(%{"cache" => %{"status" => "HIT"}}), do: :hit
  defp parse_cache_status(_), do: :miss

  defp parse_cacheable(%{"cacheable" => true}), do: true
  defp parse_cacheable(%{"cacheable" => false}), do: false
  defp parse_cacheable(_), do: false

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
