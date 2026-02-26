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
            status: :pending | :running | :done | :failed,
            assigned_to: String.t() | nil,
            run_id: String.t() | nil,
            agent_info: AgentInfo.t() | nil,
            started_at_mono: integer() | nil
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
      :run_id,
      :agent_info,
      :started_at_mono
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
    registry = Keyword.get(opts, :registry, @default_registry)
    name = {:via, Registry, {registry, {session_id, run_id}}}
    GenServer.start_link(__MODULE__, {graph, run_id, session_id, plugin, context}, name: name)
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

  # ── Server callbacks ────────────────────────────────────────────────

  @impl true
  def init({%TaskGraph{} = graph, run_id, session_id, plugin, context}) do
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
           run_id: run_id,
           agent_info: nil,
           started_at_mono: nil
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
      frontier: frontier
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
  def handle_call({:report_result, task_id, :success}, _from, state) do
    case Map.fetch(state.tasks, task_id) do
      :error ->
        {:reply, {:error, :unknown_task}, state}

      {:ok, task_state} ->
        updated_task = %{task_state | status: :done, assigned_to: nil}

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

        {:reply, {:ok, compute_run_status(tasks)}, new_state}
    end
  end

  @impl true
  def handle_call({:report_result, task_id, :failed}, _from, state) do
    case Map.fetch(state.tasks, task_id) do
      :error ->
        {:reply, {:error, :unknown_task}, state}

      {:ok, task_state} ->
        updated_task = %{task_state | status: :failed, assigned_to: nil}

        tasks = Map.put(state.tasks, task_id, updated_task)

        # Propagate failure transitively to all dependents
        tasks = propagate_failure(tasks, task_state.dependents)

        # Free the agent
        agents =
          case task_state.assigned_to do
            nil -> state.agents
            aid -> Map.delete(state.agents, aid)
          end

        # Recompute frontier (may be empty after failure propagation)
        frontier = compute_frontier(tasks)
        new_state = %{state | tasks: tasks, agents: agents, frontier: frontier}

        # Notify plugin of task completion (wrapped in try/catch for resilience)
        notify_plugin_task_complete(state, task_state, :failed)

        {:reply, {:ok, compute_run_status(tasks)}, new_state}
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
  def handle_call(:status, _from, state) do
    run_status = compute_run_status(state.tasks)

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
            dep_task -> dep_task.status == :done
          end
        end)
    end)
    |> MapSet.new(fn {id, _t} -> id end)
  end

  defp propagate_failure(tasks, dependent_ids) do
    Enum.reduce(dependent_ids, tasks, fn dep_id, acc ->
      dep_task = acc[dep_id]

      if dep_task && dep_task.status in [:pending, :running] do
        updated = %{dep_task | status: :failed, assigned_to: nil}
        acc = Map.put(acc, dep_id, updated)
        # Recursively propagate to this task's dependents
        propagate_failure(acc, dep_task.dependents)
      else
        acc
      end
    end)
  end

  defp compute_run_status(tasks) do
    statuses = tasks |> Map.values() |> Enum.map(& &1.status)

    cond do
      Enum.any?(statuses, &(&1 == :failed)) and
          Enum.all?(statuses, &(&1 in [:done, :failed])) ->
        :failed

      Enum.all?(statuses, &(&1 == :done)) ->
        :complete

      true ->
        :running
    end
  end
end
