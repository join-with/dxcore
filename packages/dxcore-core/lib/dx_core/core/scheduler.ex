defmodule DxCore.Core.Scheduler do
  @moduledoc """
  GenServer that manages the task DAG execution.

  Tracks task states (pending/running/done/failed), assigns frontier
  tasks to agents, unblocks dependents on completion, and propagates
  failure transitively. Pre-marks cache hits as done during init.

  Accepts a `plugin:` option implementing `DxCore.Core.SchedulerPlugin`
  to customize task selection and graph expansion.

  Accepts an optional `context:` map (default `%{}`) that is passed to
  all plugin callbacks for tenant-scoped metadata.
  """

  use GenServer

  alias DxCore.Core.AgentInfo
  alias DxCore.Core.TaskGraph

  # ── Task state tracked per task ──────────────────────────────────────

  defmodule TaskState do
    @moduledoc false

    @type t :: %__MODULE__{
            task_id: String.t(),
            task: String.t(),
            package: String.t(),
            hash: String.t(),
            command: String.t(),
            deps: [String.t()],
            dependents: [String.t()],
            shard: map() | nil,
            status: :pending | :running | :done | :failed | :skipped,
            assigned_to: String.t() | nil,
            completed_by: String.t() | nil,
            run_id: String.t() | nil,
            agent_info: AgentInfo.t() | nil,
            started_at_mono: integer() | nil,
            exit_code: integer() | nil,
            duration_ms: integer() | nil,
            cache_status: :hit | :miss
          }

    defstruct [
      :task_id,
      :task,
      :package,
      :hash,
      :command,
      :deps,
      :dependents,
      :shard,
      :status,
      :assigned_to,
      :completed_by,
      :run_id,
      :agent_info,
      :started_at_mono,
      :exit_code,
      :duration_ms,
      :cache_status
    ]
  end

  # ── Client API ──────────────────────────────────────────────────────

  @default_registry DxCore.Core.SchedulerRegistry

  @doc """
  Start the scheduler with `graph:`, `run_id:`, `session_id:`, `plugin:`,
  and optional `context:` and `registry:` options.

  The `:registry` option defaults to `DxCore.Core.SchedulerRegistry`.
  """
  def start_link(opts) do
    graph = Keyword.fetch!(opts, :graph)
    run_id = Keyword.fetch!(opts, :run_id)
    session_id = Keyword.fetch!(opts, :session_id)
    plugin = Keyword.fetch!(opts, :plugin)
    context = Keyword.get(opts, :context, %{})
    failure_strategy = Keyword.get(opts, :failure_strategy, :fail_fast)
    registry = Keyword.get(opts, :registry, @default_registry)
    name = {:via, Registry, {registry, {session_id, run_id}}}

    GenServer.start_link(
      __MODULE__,
      {graph, run_id, session_id, plugin, context, failure_strategy},
      name: name
    )
  end

  @doc "Look up the pid of a scheduler by session_id and run_id, or nil if not found."
  def whereis(session_id, run_id, registry \\ @default_registry) do
    case Registry.lookup(registry, {session_id, run_id}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc "Return `[{pid, run_id}]` for all schedulers registered under `session_id`."
  def list_for_session(session_id, registry \\ @default_registry) do
    Registry.select(registry, [
      {{{session_id, :"$1"}, :"$2", :_}, [], [{{:"$2", :"$1"}}]}
    ])
  end

  @doc """
  Request the next available task for `agent_id`.

  Optionally accepts an `AgentInfo` struct as third argument
  (defaults to `%AgentInfo{}`).

  Returns `{:ok, %TaskState{}}` or `:no_task`.
  """
  def request_task(pid, agent_id, agent_info \\ %AgentInfo{}) do
    GenServer.call(pid, {:request_task, agent_id, agent_info})
  end

  @doc """
  Report the result of a task execution.

  `result` is `:success` or `:failed`.
  Returns `{:ok, run_status}` where run_status is `:running`, `:complete`, or `:failed`.
  """
  def report_result(pid, task_id, result) do
    GenServer.call(pid, {:report_result, task_id, result})
  end

  @doc "Return any task assigned to `agent_id` back to the frontier."
  def reassign_task(pid, agent_id) do
    GenServer.call(pid, {:reassign_task, agent_id})
  end

  @doc "Return the current scheduler status."
  def status(pid) do
    GenServer.call(pid, :status)
  end

  @doc "Return a structured summary of the run."
  def summary(pid) do
    GenServer.call(pid, :summary)
  end

  # ── Server callbacks ────────────────────────────────────────────────

  @impl true
  def init({%TaskGraph{} = graph, run_id, session_id, plugin, context, failure_strategy}) do
    # Let the plugin expand the graph before scheduling
    %TaskGraph{tasks: graph_tasks} = plugin.expand_graph(graph, context)

    # Build TaskState entries from graph tasks
    tasks =
      Map.new(graph_tasks, fn {id, t} ->
        {id,
         %TaskState{
           task_id: t.task_id,
           task: t.task,
           package: t.package,
           hash: t.hash,
           command: t.command,
           deps: t.deps,
           dependents: t.dependents,
           shard: t.shard,
           status: if(t.cache_status == :hit, do: :done, else: :pending),
           assigned_to: nil,
           completed_by: nil,
           run_id: run_id,
           agent_info: nil,
           started_at_mono: nil,
           exit_code: nil,
           duration_ms: nil,
           cache_status: t.cache_status
         }}
      end)

    frontier = compute_frontier(tasks)

    state = %{
      run_id: run_id,
      session_id: session_id,
      plugin: plugin,
      context: context,
      tasks: tasks,
      agents: %{},
      frontier: frontier,
      failure_strategy: failure_strategy,
      failed_fast: false
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:request_task, agent_id, agent_info}, _from, state) do
    # Build list of frontier TaskState structs for the plugin
    frontier_tasks =
      state.frontier
      |> MapSet.to_list()
      |> Enum.map(fn task_id -> state.tasks[task_id] end)

    case state.plugin.select_task(frontier_tasks, agent_info, state.context) do
      nil ->
        {:reply, :no_task, state}

      selected_task ->
        task_id = selected_task.task_id

        updated_task = %{
          selected_task
          | status: :running,
            assigned_to: agent_id,
            agent_info: agent_info,
            started_at_mono: System.monotonic_time(:millisecond)
        }

        new_state = %{
          state
          | tasks: Map.put(state.tasks, task_id, updated_task),
            agents: Map.put(state.agents, agent_id, task_id),
            frontier: MapSet.delete(state.frontier, task_id)
        }

        {:reply, {:ok, updated_task}, new_state}
    end
  end

  @impl true
  def handle_call({:report_result, task_id, {result_atom, exit_code}}, from, state)
      when result_atom in [:success, :failed] do
    case Map.fetch(state.tasks, task_id) do
      :error ->
        {:reply, {:error, :unknown_task}, state}

      {:ok, task_state} ->
        duration_ms = compute_duration(task_state)
        updated_task = %{task_state | exit_code: exit_code, duration_ms: duration_ms}
        state = %{state | tasks: Map.put(state.tasks, task_id, updated_task)}
        handle_call({:report_result, task_id, result_atom}, from, state)
    end
  end

  @impl true
  def handle_call({:report_result, task_id, :success}, _from, state) do
    case Map.fetch(state.tasks, task_id) do
      :error ->
        {:reply, {:error, :unknown_task}, state}

      {:ok, task_state} ->
        duration_ms = task_state.duration_ms || compute_duration(task_state)

        updated_task = %{
          task_state
          | status: :done,
            assigned_to: nil,
            completed_by: task_state.assigned_to,
            duration_ms: duration_ms
        }

        tasks = Map.put(state.tasks, task_id, updated_task)

        # Free the agent
        agents =
          case task_state.assigned_to do
            nil -> state.agents
            aid -> Map.delete(state.agents, aid)
          end

        # Recompute frontier with the newly completed task
        frontier = compute_frontier(tasks)
        new_state = %{state | tasks: tasks, agents: agents, frontier: frontier}

        # Notify plugin of task completion (wrapped in try/catch for resilience)
        notify_plugin_task_complete(state, task_state, :success)

        {:reply, {:ok, compute_run_status(tasks, state.failed_fast)}, new_state}
    end
  end

  @impl true
  def handle_call({:report_result, task_id, :failed}, _from, state) do
    case Map.fetch(state.tasks, task_id) do
      :error ->
        {:reply, {:error, :unknown_task}, state}

      {:ok, task_state} ->
        duration_ms = task_state.duration_ms || compute_duration(task_state)

        updated_task = %{
          task_state
          | status: :failed,
            assigned_to: nil,
            completed_by: task_state.assigned_to,
            duration_ms: duration_ms
        }

        tasks = Map.put(state.tasks, task_id, updated_task)

        # Apply failure strategy
        tasks =
          case state.failure_strategy do
            :continue_all -> propagate_skipped(tasks, task_state.dependents)
            :fail_fast -> skip_all_pending(tasks)
          end

        failed_fast = state.failed_fast || state.failure_strategy == :fail_fast

        # Free the agent
        agents =
          case task_state.assigned_to do
            nil -> state.agents
            aid -> Map.delete(state.agents, aid)
          end

        # Recompute frontier (may be empty after failure propagation)
        frontier = compute_frontier(tasks)

        new_state = %{
          state
          | tasks: tasks,
            agents: agents,
            frontier: frontier,
            failed_fast: failed_fast
        }

        # Notify plugin of task completion (wrapped in try/catch for resilience)
        notify_plugin_task_complete(state, task_state, :failed)

        {:reply, {:ok, compute_run_status(tasks, failed_fast)}, new_state}
    end
  end

  @impl true
  def handle_call({:reassign_task, agent_id}, _from, state) do
    # Find the task currently assigned to this agent
    task_entry =
      Enum.find(state.tasks, fn {_id, t} ->
        t.assigned_to == agent_id and t.status == :running
      end)

    case task_entry do
      nil ->
        {:reply, :ok, state}

      {task_id, task_state} ->
        updated_task = %{task_state | status: :pending, assigned_to: nil}
        tasks = Map.put(state.tasks, task_id, updated_task)
        agents = Map.delete(state.agents, agent_id)
        frontier = compute_frontier(tasks)

        {:reply, :ok, %{state | tasks: tasks, agents: agents, frontier: frontier}}
    end
  end

  @impl true
  def handle_call(:summary, _from, state) do
    {:reply, build_summary(state), state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    run_status = compute_run_status(state.tasks, state.failed_fast)

    reply = %{
      run_id: state.run_id,
      run_status: run_status,
      tasks: state.tasks,
      agents: state.agents,
      frontier: state.frontier
    }

    {:reply, reply, state}
  end

  # ── Private helpers ─────────────────────────────────────────────────

  defp compute_duration(%{started_at_mono: nil}), do: 0

  defp compute_duration(%{started_at_mono: started}),
    do: System.monotonic_time(:millisecond) - started

  defp notify_plugin_task_complete(state, task_state, result) do
    duration_ms =
      case task_state.started_at_mono do
        nil -> 0
        started -> System.monotonic_time(:millisecond) - started
      end

    agent_info = task_state.agent_info || %AgentInfo{}

    try do
      state.plugin.on_task_complete(task_state, result, duration_ms, agent_info, state.context)
    rescue
      e ->
        require Logger
        Logger.warning("Plugin on_task_complete failed: #{inspect(e)}")
        :ok
    catch
      kind, reason ->
        require Logger
        Logger.warning("Plugin on_task_complete failed (#{kind}): #{inspect(reason)}")
        :ok
    end
  end

  defp compute_frontier(tasks) do
    tasks
    |> Enum.filter(fn {_id, t} ->
      t.status == :pending and
        Enum.all?(t.deps, fn dep ->
          case tasks[dep] do
            nil -> false
            dep_task -> dep_task.status in [:done, :skipped]
          end
        end)
    end)
    |> MapSet.new(fn {id, _t} -> id end)
  end

  defp propagate_skipped(tasks, dependent_ids) do
    Enum.reduce(dependent_ids, tasks, fn dep_id, acc ->
      dep_task = acc[dep_id]

      if dep_task && dep_task.status == :pending do
        updated = %{dep_task | status: :skipped}
        acc = Map.put(acc, dep_id, updated)
        propagate_skipped(acc, dep_task.dependents)
      else
        acc
      end
    end)
  end

  defp skip_all_pending(tasks) do
    Map.new(tasks, fn {id, task} ->
      if task.status == :pending do
        {id, %{task | status: :skipped}}
      else
        {id, task}
      end
    end)
  end

  defp build_summary(state) do
    tasks_list =
      state.tasks
      |> Enum.map(fn {_id, t} ->
        %{
          task_id: t.task_id,
          package: t.package,
          task: t.task,
          status: t.status,
          cached: t.cache_status == :hit,
          agent_id: t.completed_by || t.assigned_to,
          duration_ms: t.duration_ms,
          exit_code: t.exit_code
        }
      end)
      |> Enum.sort_by(& &1.task_id)

    done_non_cached = Enum.count(tasks_list, &(&1.status == :done and not &1.cached))
    cached = Enum.count(tasks_list, & &1.cached)
    failed = Enum.count(tasks_list, &(&1.status == :failed))
    skipped = Enum.count(tasks_list, &(&1.status == :skipped))

    failures =
      state.tasks
      |> Enum.filter(fn {_id, t} -> t.status == :failed end)
      |> Enum.map(fn {_id, t} ->
        %{
          task_id: t.task_id,
          agent_id: t.completed_by || t.assigned_to,
          duration_ms: t.duration_ms,
          exit_code: t.exit_code
        }
      end)
      |> Enum.sort_by(& &1.task_id)

    %{
      status: compute_run_status(state.tasks, state.failed_fast),
      tasks: tasks_list,
      counts: %{passed: done_non_cached, failed: failed, skipped: skipped, cached: cached},
      failures: failures
    }
  end

  defp compute_run_status(tasks, failed_fast) do
    statuses = tasks |> Map.values() |> Enum.map(& &1.status)

    cond do
      failed_fast and Enum.all?(statuses, &(&1 in [:done, :failed, :skipped])) ->
        :failed

      Enum.any?(statuses, &(&1 == :failed)) and
          Enum.all?(statuses, &(&1 in [:done, :failed, :skipped])) ->
        :failed

      Enum.all?(statuses, &(&1 in [:done, :skipped])) ->
        :complete

      true ->
        :running
    end
  end
end
