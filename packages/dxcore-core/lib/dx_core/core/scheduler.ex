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

  # :transient: a scheduler that gives up on loading its run's state stops
  # with `{:shutdown, _}` and is not restarted, so it cannot crash-loop the
  # supervisor every run's scheduler shares (#11994). The run is rebuilt from
  # the database on the next agent result or dispatcher rejoin. A crash is
  # still restarted.
  use GenServer, restart: :transient

  require Logger

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
            requirements: map(),
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
      :cache_status,
      requirements: %{}
    ]
  end

  # ── Client API ──────────────────────────────────────────────────────

  @default_registry DxCore.Core.SchedulerRegistry

  # Agents rejoin within a second of a restart, but on a drain their sockets
  # stay on the old pod for its drain wait (10 s) while the scheduler has
  # already moved, so the window has to outlast that.
  @default_lease_grace_ms 30_000

  # Waits between attempts to load the run's state. They add up to 3.1 s,
  # under GenServer.call's 5 s default, so a caller that arrives meanwhile
  # waits instead of timing out.
  @default_state_load_backoff_ms [100, 200, 400, 800, 1_600]

  # Registry module used for `{:via, _, _}` naming, lookup, and select. Defaults
  # to the local `Registry` (OSS coordinator). SaaS overrides via
  # `config :dxcore_core, :scheduler_via_module, Horde.Registry` so the same
  # process registration works across a Horde-distributed cluster. Tests can
  # also pass `:via_module` per call to keep using a local Registry without
  # touching app config.
  defp default_via_module do
    Application.get_env(:dxcore_core, :scheduler_via_module, Registry)
  end

  @doc """
  Start the scheduler.

  Required options:
  - `:graph` — `%TaskGraph{}` to schedule.
  - `:run_id` — DB run UUID.
  - `:session_id` — session identifier (used for Registry naming).
  - `:plugin` — module implementing `DxCore.Core.SchedulerPlugin`.

  Optional options:
  - `:context` (default `%{}`) — passed verbatim to plugin callbacks for tenant-scoped metadata.
  - `:failure_strategy` (default `:fail_fast`) — `:fail_fast` or `:continue_all`.
  - `:registry` (default `DxCore.Core.SchedulerRegistry`) — Registry used for `{:via, ...}` naming.
  - `:skip_expand?` (default `false`) — when `true`, the scheduler trusts that `graph` was already
    expanded by the caller (e.g. `submit_graph` running plugin.expand_graph/2 ahead of persistence).
    Skipping expansion is required during rehydration so the rebuilt scheduler operates on the
    same graph the original ran with.
  - `:rehydrate_from` (default `[]`) — list of result maps with the shape
    `%{task_id: String.t(), status: :done | :failed | :skipped, agent_id: String.t() | nil,
       duration_ms: integer() | nil}`, plus an optional `exit_code: integer() | nil`. Each entry is
    applied to the corresponding task in `graph`, setting `status`, `duration_ms`, `exit_code`
    and `completed_by`. Unknown task_ids (cache flips) are skipped.
    After applying results, dependents of any `:failed` rehydrated task are marked `:skipped`.
    When non-empty, the scheduler also assumes topology has settled.
  - `:state_loader` (default: the `:dxcore_core, :scheduler_state_loader` app
    env, else `nil`) — `{module, function, extra_args}` called as
    `apply(module, function, [run_id | extra_args])` every time the scheduler
    starts, before it handles any message. It returns
    `{:ok, %{results: results, leases: leases}}`: `results` in the
    `:rehydrate_from` shape, and `leases` as
    `%{task_id: String.t(), agent_id: String.t(), assigned_at: DateTime.t() | nil}`
    for tasks handed to an agent. A supervisor that restarts the scheduler
    (Horde, when it moves the process to another node on a drain or a node
    loss) restarts it from the child spec it was first started with, so the
    loader, not the start options, is what carries the run's progress across
    the restart. The app env default covers a scheduler whose child spec was
    built by code that did not pass the option yet. A persisted result wins
    over a `:rehydrate_from` entry for the same task, which only fills in
    tasks with no persisted result. A failed load (the loader raises,
    exits or returns another shape) is retried after each wait in
    `:state_load_backoff_ms` (default #{inspect(@default_state_load_backoff_ms)});
    when every attempt fails the scheduler stops with
    `{:shutdown, {:state_load_failed, reason}}` instead of starting from the
    bare graph, which would hand finished tasks out again and reject the
    results of in-flight ones.
  - `:lease_grace_ms` (default #{@default_lease_grace_ms}) — how long a held
    lease is kept for an agent that is not connected: one restored by the
    loader, or one of an agent whose connection dropped (`hold_agent/2`).
    Once its window has passed, a held lease whose agent is absent is
    released; one whose agent is back is checked again a window later.
  """
  def start_link(opts) do
    graph = Keyword.fetch!(opts, :graph)
    run_id = Keyword.fetch!(opts, :run_id)
    session_id = Keyword.fetch!(opts, :session_id)
    plugin = Keyword.fetch!(opts, :plugin)
    context = Keyword.get(opts, :context, %{})
    failure_strategy = Keyword.get(opts, :failure_strategy, :fail_fast)
    skip_expand? = Keyword.get(opts, :skip_expand?, false)
    rehydrate_from = Keyword.get(opts, :rehydrate_from, [])
    registry = Keyword.get(opts, :registry, @default_registry)
    via_module = Keyword.get(opts, :via_module, default_via_module())
    # `org_id` defaults to nil for the OSS coordinator (single-tenant). SaaS
    # callers pass the connected organization's id so that `{org_id, session_id,
    # run_id}` is unique even if a malicious tenant manages to match another
    # tenant's session_id + run_id pair.
    org_id = Keyword.get(opts, :org_id)
    name = {:via, via_module, {registry, {org_id, session_id, run_id}}}

    restore = %{
      state_loader:
        Keyword.get_lazy(opts, :state_loader, fn ->
          Application.get_env(:dxcore_core, :scheduler_state_loader)
        end),
      lease_grace_ms: Keyword.get(opts, :lease_grace_ms, @default_lease_grace_ms),
      state_load_backoff_ms:
        Keyword.get(opts, :state_load_backoff_ms, @default_state_load_backoff_ms)
    }

    GenServer.start_link(
      __MODULE__,
      {graph, run_id, session_id, plugin, context, failure_strategy, skip_expand?, rehydrate_from,
       restore},
      name: name
    )
  end

  @doc """
  Look up the pid of a scheduler registered under `{org_id, session_id, run_id}`,
  or nil if not registered. OSS callers (single-tenant) pass `nil` for `org_id`.
  """
  def whereis(
        org_id,
        session_id,
        run_id,
        registry \\ @default_registry,
        via_module \\ default_via_module()
      ) do
    case via_module.lookup(registry, {org_id, session_id, run_id}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc """
  Return `[{pid, run_id}]` for all schedulers registered under
  `{org_id, session_id}`. OSS callers pass `nil` for `org_id`.
  """
  def list_for_session(
        org_id,
        session_id,
        registry \\ @default_registry,
        via_module \\ default_via_module()
      ) do
    via_module.select(registry, [
      {{{org_id, session_id, :"$1"}, :"$2", :_}, [], [{{:"$2", :"$1"}}]}
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

  `agent_id` must match the agent the task was assigned to (lease holder).
  `result` is `:success`, `:failed`, `{:success, exit_code}`, or `{:failed, exit_code}`.

  Returns:
  - `{:ok, run_status}` on success, where run_status is `:running`, `:complete`, or `:failed`.
  - `{:error, :not_assigned}` if the task is not currently assigned to `agent_id`,
    or its status is not `:running`.
  - `{:error, :unknown_task}` if `task_id` does not exist in this scheduler.
  """
  def report_result(pid, task_id, agent_id, result) do
    GenServer.call(pid, {:report_result, task_id, agent_id, result})
  end

  @doc "Release every task assigned to `agent_id` (see `release_agent/3`)."
  def reassign_task(pid, agent_id), do: release_agent(pid, agent_id)

  @doc """
  The connection of `agent_id` dropped, but the agent may still be running
  its tasks (a pod drain closes the sockets of busy agents). Keep them on it
  for `:lease_grace_ms`, then release each one whose agent has not come back.
  An agent that comes back says what it runs (`release_agent/3`).
  """
  def hold_agent(pid, agent_id) do
    GenServer.call(pid, {:hold_agent, agent_id})
  end

  @doc """
  Release every task assigned to `agent_id` except `keep_task_id`: each goes
  back to the frontier, or is skipped once a `:fail_fast` run has failed.
  Used when the agent disconnects (`keep_task_id` nil) and when it announces
  what it is running (the task it names is kept).
  """
  def release_agent(pid, agent_id, keep_task_id \\ nil) do
    GenServer.call(pid, {:release_agent, agent_id, keep_task_id})
  end

  @doc "Return the current scheduler status."
  def status(pid) do
    GenServer.call(pid, :status)
  end

  @doc """
  Return the scheduler's stored `:dispatcher_topic` from its context, or `nil`
  if not set. Used by channel helpers to broadcast run-scoped events without
  re-deriving the topic from socket assigns (which may be session-scoped).
  """
  def dispatcher_topic(pid) do
    GenServer.call(pid, :dispatcher_topic)
  end

  @doc "Return a structured summary of the run."
  def summary(pid) do
    GenServer.call(pid, :summary)
  end

  @doc "Trigger topology evaluation. Called when agents connect or disconnect."
  def check_topology(pid) do
    GenServer.cast(pid, :check_topology)
  end

  # ── Server callbacks ────────────────────────────────────────────────

  @impl true
  def init(
        {%TaskGraph{} = graph, run_id, session_id, plugin, context, failure_strategy,
         skip_expand?, rehydrate_from, restore}
      ) do
    # Let the plugin expand the graph before scheduling, unless caller already did so
    graph =
      if skip_expand? do
        graph
      else
        plugin.expand_graph(graph, context)
      end

    state = %{
      run_id: run_id,
      session_id: session_id,
      plugin: plugin,
      context: context,
      tasks: build_initial_tasks(graph, run_id),
      agents: %{},
      frontier: MapSet.new(),
      failure_strategy: failure_strategy,
      failed_fast: false,
      topology_check: Map.get(context, :topology_check, "infer"),
      expected_agents: get_in(context, [:topology, "agents"]),
      topology_timer: nil,
      topology_settled: false,
      # task_id => {agent_id, deadline}: leases kept on an agent that is not
      # connected, released after the deadline if the agent is still absent.
      held_leases: %{},
      lease_timer: nil,
      lease_grace_ms: restore.lease_grace_ms
    }

    # The persisted state is loaded in handle_continue, which runs before any
    # message is handled, so a supervisor starting many schedulers at once
    # (Horde moving a drained node's runs) is not held up by the queries.
    {:ok, state,
     {:continue, {:restore, rehydrate_from, restore.state_loader, restore.state_load_backoff_ms}}}
  end

  @impl true
  def handle_continue({:restore, rehydrate_from, state_loader, backoff_ms}, state) do
    case load_state_retrying(state_loader, state.run_id, backoff_ms) do
      {:ok, loaded} ->
        {:noreply, restore(state, loaded, rehydrate_from)}

      {:error, reason} ->
        {:stop, {:shutdown, {:state_load_failed, reason}}, state}
    end
  end

  defp restore(state, %{results: loaded_results, leases: leases}, rehydrate_from) do
    results = merge_results(loaded_results, rehydrate_from)

    tasks =
      state.tasks
      |> restore_leases(leases)
      |> apply_rehydration(results, state.failure_strategy)

    restored =
      for {task_id, %TaskState{status: :running, assigned_to: agent_id}} <- tasks,
          do: {task_id, agent_id}

    state = %{
      state
      | tasks: tasks,
        agents: agents_from_tasks(tasks),
        frontier: compute_frontier(tasks),
        failed_fast: failed_fast_from_results(results, state.failure_strategy),
        # A scheduler rebuilt from persisted progress assumes topology has
        # already settled; a fresh submit has none and uses the live timer.
        topology_settled: results != [] or restored != []
    }

    hold_leases(state, restored)
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

        notify_plugin_task_assigned(state, updated_task, agent_info)
        {:reply, {:ok, updated_task}, new_state}
    end
  end

  # An agent runs one task at a time, so once it reports a result it holds
  # nothing else: any other task still marked as running on it was pushed to
  # it while it was busy (a reconnecting agent announces itself even mid-task
  # and ignores a second assignment), and it goes back to the frontier.
  @impl true
  def handle_call({:report_result, task_id, agent_id, result}, _from, state) do
    {reply, state} = do_report_result(task_id, agent_id, result, state)
    {:reply, reply, release_tasks_held_by(state, agent_id, task_id, :reported_other)}
  end

  @impl true
  def handle_call({:hold_agent, agent_id}, _from, state) do
    held =
      for {task_id, %TaskState{status: :running, assigned_to: ^agent_id}} <- state.tasks,
          do: {task_id, agent_id}

    {:reply, :ok, hold_leases(state, held)}
  end

  @impl true
  def handle_call({:release_agent, agent_id, keep_task_id}, _from, state) do
    {:reply, :ok, release_tasks_held_by(state, agent_id, keep_task_id, :released)}
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

  @impl true
  def handle_call(:dispatcher_topic, _from, state) do
    {:reply, Map.get(state.context, :dispatcher_topic), state}
  end

  @impl true
  def handle_cast(:check_topology, state) do
    alias DxCore.Core.Scheduler.TopologyEvaluator
    {:noreply, TopologyEvaluator.evaluate(state)}
  end

  @impl true
  def handle_info(:check_held_leases, state) do
    now = System.monotonic_time(:millisecond)

    present =
      state
      |> DxCore.Core.Scheduler.TopologyEvaluator.list_agents()
      |> MapSet.new(& &1.agent_id)

    # A lease that no longer stands (the task finished, or went to another
    # agent) is dropped; one whose window has not passed waits.
    {due, waiting} =
      state.held_leases
      |> Enum.filter(fn {task_id, {agent_id, _deadline}} ->
        match?(%TaskState{status: :running, assigned_to: ^agent_id}, state.tasks[task_id])
      end)
      |> Enum.split_with(fn {_task_id, {_agent_id, deadline}} -> deadline <= now end)

    {released, kept} =
      Enum.split_with(due, fn {_task_id, {agent_id, _}} ->
        not MapSet.member?(present, agent_id)
      end)

    held =
      Map.new(waiting)
      |> Map.merge(
        Map.new(kept, fn {task_id, {agent_id, _}} ->
          {task_id, {agent_id, now + state.lease_grace_ms}}
        end)
      )

    state = %{state | held_leases: held, lease_timer: nil}

    state =
      Enum.reduce(released, state, fn {task_id, {agent_id, _deadline}}, acc ->
        Logger.warning(
          "Releasing task #{task_id} of run #{state.run_id}: its agent " <>
            "#{inspect(agent_id)} has not come back"
        )

        release_task(acc, task_id)
      end)

    state = schedule_lease_check(state)
    if released != [], do: broadcast_tasks_available(state)

    # One event per check: which held leases it released (agent absent past
    # the window), kept (agent back; a new window starts) and left waiting
    # (window not over yet).
    :telemetry.execute(
      [:dxcore, :scheduler, :held_leases_checked],
      %{released: length(released), kept: length(kept)},
      %{
        run_id: state.run_id,
        checked_at: now,
        released: Enum.map(released, &elem(&1, 0)),
        kept: Enum.map(kept, &elem(&1, 0)),
        waiting: Enum.map(waiting, &elem(&1, 0))
      }
    )

    {:noreply, state}
  end

  @impl true
  def handle_info(:topology_stabilized, state) do
    alias DxCore.Core.Scheduler.TopologyEvaluator
    new_state = %{state | topology_settled: true, topology_timer: nil}
    {:noreply, TopologyEvaluator.evaluate_assignability(new_state)}
  end

  # ── Private helpers ─────────────────────────────────────────────────

  defp do_report_result(task_id, agent_id, {result_atom, exit_code}, state)
       when result_atom in [:success, :failed] do
    with {:ok, %TaskState{assigned_to: ^agent_id, status: :running} = task_state} <-
           Map.fetch(state.tasks, task_id) do
      duration_ms = compute_duration(task_state)
      updated_task = %{task_state | exit_code: exit_code, duration_ms: duration_ms}
      state = %{state | tasks: Map.put(state.tasks, task_id, updated_task)}
      do_report_result(task_id, agent_id, result_atom, state)
    else
      result -> reply_ack_rejection(result, state, agent_id, task_id)
    end
  end

  defp do_report_result(task_id, agent_id, :success, state) do
    with {:ok, %TaskState{assigned_to: ^agent_id, status: :running} = task_state} <-
           Map.fetch(state.tasks, task_id) do
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

      {{:ok, compute_run_status(tasks, state.failed_fast)}, new_state}
    else
      result -> reply_ack_rejection(result, state, agent_id, task_id)
    end
  end

  defp do_report_result(task_id, agent_id, :failed, state) do
    with {:ok, %TaskState{assigned_to: ^agent_id, status: :running} = task_state} <-
           Map.fetch(state.tasks, task_id) do
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

      {{:ok, compute_run_status(tasks, failed_fast)}, new_state}
    else
      result -> reply_ack_rejection(result, state, agent_id, task_id)
    end
  end

  defp compute_duration(%{started_at_mono: nil}), do: 0

  defp compute_duration(%{started_at_mono: started}),
    do: System.monotonic_time(:millisecond) - started

  defp reply_ack_rejection({:ok, %TaskState{} = t}, state, agent_id, task_id) do
    log_and_emit_ack_rejected(agent_id, task_id, state.run_id, :wrong_agent_or_status, t)
    {{:error, :not_assigned}, state}
  end

  defp reply_ack_rejection(:error, state, agent_id, task_id) do
    log_and_emit_ack_rejected(agent_id, task_id, state.run_id, :unknown_task, nil)
    {{:error, :unknown_task}, state}
  end

  defp log_and_emit_ack_rejected(agent_id, task_id, run_id, reason, task) do
    log_msg =
      case task do
        %TaskState{} = t ->
          "ACK rejected: agent=#{inspect(agent_id)} task=#{task_id} run=#{run_id} " <>
            "(actual assigned_to=#{inspect(t.assigned_to)}, status=#{t.status})"

        nil ->
          "ACK rejected: agent=#{inspect(agent_id)} task=#{task_id} run=#{run_id} " <>
            "(unknown task)"
      end

    Logger.warning(log_msg)

    :telemetry.execute(
      [:dxcore, :scheduler, :ack_rejected],
      %{count: 1},
      %{agent_id: agent_id, task_id: task_id, run_id: run_id, reason: reason}
    )
  end

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
        Logger.warning("Plugin on_task_complete failed: #{inspect(e)}")
        :ok
    catch
      kind, reason ->
        Logger.warning("Plugin on_task_complete failed (#{kind}): #{inspect(reason)}")
        :ok
    end
  end

  defp notify_plugin_task_assigned(state, task, agent_info),
    do: notify_plugin(state, :on_task_assigned, [task, agent_info, state.context])

  # Calls an optional plugin callback; a failure is logged and ignored.
  defp notify_plugin(state, callback, args) do
    if Code.ensure_loaded?(state.plugin) and
         function_exported?(state.plugin, callback, length(args)) do
      try do
        apply(state.plugin, callback, args)
      rescue
        e -> Logger.warning("Plugin #{callback} failed: #{inspect(e)}")
      catch
        kind, reason ->
          Logger.warning("Plugin #{callback} failed (#{kind}): #{inspect(reason)}")
      end
    end

    :ok
  end

  # Loads the run's persisted progress, retrying a failure after each wait
  # in `backoff_ms`. Every failed attempt is logged and counted.
  defp load_state_retrying(loader, run_id, backoff_ms) do
    case load_state(loader, run_id) do
      {:ok, loaded} ->
        {:ok, loaded}

      {:error, reason} ->
        state_load_failed(run_id, reason, backoff_ms)

        case backoff_ms do
          [] ->
            {:error, reason}

          [wait | rest] ->
            Process.sleep(wait)
            load_state_retrying(loader, run_id, rest)
        end
    end
  end

  defp load_state(nil, _run_id), do: {:ok, %{results: [], leases: []}}

  defp load_state({module, function, args}, run_id)
       when is_atom(module) and is_atom(function) and is_list(args) do
    case apply(module, function, [run_id | args]) do
      {:ok, %{results: results, leases: leases}} when is_list(results) and is_list(leases) ->
        {:ok, %{results: results, leases: leases}}

      other ->
        {:error, {:bad_return, other}}
    end
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp load_state(loader, _run_id), do: {:error, {:bad_loader, loader}}

  defp state_load_failed(run_id, reason, backoff_ms) do
    next = if backoff_ms == [], do: "giving up", else: "retrying in #{hd(backoff_ms)} ms"

    Logger.error(
      "Scheduler for run #{run_id} could not load its state (#{next}): #{inspect(reason)}"
    )

    :telemetry.execute([:dxcore, :scheduler, :state_load_failed], %{count: 1}, %{
      run_id: run_id,
      final: backoff_ms == []
    })
  end

  defp merge_results(loaded, explicit) do
    loaded_ids = MapSet.new(loaded, & &1.task_id)
    loaded ++ Enum.reject(explicit, &MapSet.member?(loaded_ids, &1.task_id))
  end

  # A lease puts a task that has no result back on the agent that was running
  # it, so its result is accepted and nobody else is handed the same work.
  defp restore_leases(tasks, leases) do
    now_mono = System.monotonic_time(:millisecond)

    Enum.reduce(leases, tasks, fn lease, acc ->
      with %{task_id: task_id, agent_id: agent_id} when is_binary(agent_id) <- lease,
           %{^task_id => %TaskState{status: :pending} = task} <- acc do
        Map.put(acc, task_id, %{
          task
          | status: :running,
            assigned_to: agent_id,
            agent_info: %AgentInfo{agent_id: agent_id},
            started_at_mono: now_mono - elapsed_ms(Map.get(lease, :assigned_at))
        })
      else
        _ -> acc
      end
    end)
  end

  defp elapsed_ms(%DateTime{} = at),
    do: max(DateTime.diff(DateTime.utc_now(), at, :millisecond), 0)

  defp elapsed_ms(_), do: 0

  defp agents_from_tasks(tasks) do
    for {task_id, %TaskState{status: :running, assigned_to: agent_id}} <- tasks,
        is_binary(agent_id),
        into: %{},
        do: {agent_id, task_id}
  end

  # Every lease in `held` gets a fresh window of `:lease_grace_ms`.
  defp hold_leases(state, []), do: state

  defp hold_leases(state, held) do
    deadline = System.monotonic_time(:millisecond) + state.lease_grace_ms

    held_leases =
      Enum.reduce(held, state.held_leases, fn {task_id, agent_id}, acc ->
        Map.put(acc, task_id, {agent_id, deadline})
      end)

    schedule_lease_check(%{state | held_leases: held_leases})
  end

  # One timer at a time, for the earliest deadline. A lease added while it
  # runs has a later deadline (every window is the same length), so the
  # check it triggers reschedules for that one.
  defp schedule_lease_check(%{lease_timer: nil, held_leases: held} = state)
       when map_size(held) > 0 do
    next = held |> Map.values() |> Enum.map(&elem(&1, 1)) |> Enum.min()
    delay = max(next - System.monotonic_time(:millisecond), 0)
    %{state | lease_timer: Process.send_after(self(), :check_held_leases, delay)}
  end

  defp schedule_lease_check(state), do: state

  defp release_tasks_held_by(state, agent_id, keep_task_id, reason) do
    state.tasks
    |> Enum.filter(fn {id, t} ->
      t.status == :running and t.assigned_to == agent_id and id != keep_task_id
    end)
    |> Enum.reduce(state, fn {task_id, _t}, acc ->
      if reason == :reported_other do
        Logger.warning(
          "Task #{task_id} of run #{state.run_id} was held by #{inspect(agent_id)}, " <>
            "which reported another result; releasing it"
        )
      end

      release_task(acc, task_id)
    end)
  end

  # A released task goes back to the frontier, or is skipped once a
  # :fail_fast run has failed (it would never have started then). The
  # plugin hears of it so a persisted lease does not outlive it.
  defp release_task(state, task_id) do
    task = state.tasks[task_id]
    status = if state.failed_fast, do: :skipped, else: :pending
    tasks = Map.put(state.tasks, task_id, %{task | status: status, assigned_to: nil})

    holder = task.assigned_to

    agents =
      case state.agents do
        %{^holder => ^task_id} -> Map.delete(state.agents, holder)
        agents -> agents
      end

    notify_plugin(state, :on_task_released, [task, state.context])

    %{
      state
      | tasks: tasks,
        agents: agents,
        frontier: compute_frontier(tasks),
        held_leases: Map.delete(state.held_leases, task_id)
    }
  end

  # Wakes the session's idle agents. The payload carries this scheduler's pid
  # so they skip the registry lookup (#2143).
  defp broadcast_tasks_available(state) do
    case state.context do
      %{endpoint: endpoint, agent_topic: topic} when not is_nil(endpoint) and is_binary(topic) ->
        endpoint.broadcast(topic, "tasks_available", %{
          scheduler_pid: self(),
          run_id: state.run_id
        })

      _ ->
        :ok
    end
  end

  defp build_initial_tasks(%TaskGraph{tasks: graph_tasks}, run_id) do
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
         requirements: t.requirements,
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
  end

  defp apply_rehydration(tasks, [], _failure_strategy), do: tasks

  defp apply_rehydration(tasks, results, failure_strategy) do
    tasks =
      Enum.reduce(results, tasks, fn r, acc ->
        case Map.fetch(acc, r.task_id) do
          # task no longer in graph (e.g. cache flip), skip
          :error ->
            acc

          {:ok, task} ->
            Map.put(acc, r.task_id, %{
              task
              | status: r.status,
                duration_ms: r.duration_ms,
                exit_code: Map.get(r, :exit_code, task.exit_code),
                completed_by: r.agent_id,
                assigned_to: nil
            })
        end
      end)

    case failure_strategy do
      :fail_fast ->
        # Mirror the live :fail_fast path: a single failure short-circuits the
        # entire run by skipping every still-pending task, regardless of
        # dependency. propagate_rehydrated_failures only handles dependents,
        # which would leave independent tasks runnable on the rehydrated
        # scheduler.
        if Enum.any?(results, &(&1.status == :failed)) do
          skip_all_pending(tasks)
        else
          tasks
        end

      _ ->
        propagate_rehydrated_failures(tasks)
    end
  end

  defp propagate_rehydrated_failures(tasks) do
    failed_dependents =
      tasks
      |> Enum.filter(fn {_id, t} -> t.status == :failed end)
      |> Enum.flat_map(fn {_id, t} -> t.dependents end)

    Enum.reduce(failed_dependents, tasks, fn dep_id, acc ->
      propagate_skipped(acc, [dep_id])
    end)
  end

  defp failed_fast_from_results(results, :fail_fast),
    do: Enum.any?(results, &(&1.status == :failed))

  defp failed_fast_from_results(_, _), do: false

  defp compute_frontier(tasks) do
    tasks
    |> Enum.filter(fn {_id, t} ->
      t.status == :pending and
        Enum.all?(t.deps, fn dep ->
          case tasks[dep] do
            # A dependency on a task absent from the graph (e.g. a <NONEXISTENT>
            # no-op the dispatcher dropped) is treated as already-satisfied
            # rather than blocking the dependent forever. See #4154.
            nil -> true
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

  @doc false
  def skip_all_pending(tasks) do
    Map.new(tasks, fn {id, task} ->
      if task.status == :pending do
        {id, %{task | status: :skipped}}
      else
        {id, task}
      end
    end)
  end

  @doc """
  The summary a scheduler would give for `graph` with `results` applied, built
  without starting one: for a run that already finished, whose scheduler is
  gone.
  """
  def offline_summary(%TaskGraph{} = graph, run_id, results, failure_strategy) do
    tasks = graph |> build_initial_tasks(run_id) |> apply_rehydration(results, failure_strategy)

    build_summary(%{
      tasks: tasks,
      failed_fast: failed_fast_from_results(results, failure_strategy)
    })
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

  @doc false
  def compute_run_status(tasks, failed_fast) do
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
