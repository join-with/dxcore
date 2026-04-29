defmodule DxCore.Core.Scheduler.TopologyEvaluator do
  @moduledoc """
  Evaluates whether the current agent topology can satisfy all frontier tasks.

  Called by the Scheduler when agents connect or disconnect. Supports two modes:

  - **Explicit (Mode A):** Waits until a declared agent count is reached, then evaluates.
  - **Infer (Mode B):** Waits for a stabilization window (no topology changes), then evaluates.

  Tasks whose requirements cannot be satisfied by any connected agent are marked as failed.
  """

  require Logger

  @topology_stabilization_ms 10_000

  @doc """
  Evaluate topology based on the active mode. Returns updated state.

  Called from `Scheduler.handle_cast(:check_topology, state)`.
  """
  def evaluate(state), do: evaluate_topology(state)

  @doc """
  Run assignability evaluation immediately. Returns updated state.

  Called from `Scheduler.handle_info(:topology_stabilized, state)`.
  """
  def evaluate_assignability(state), do: do_evaluate_assignability(state)

  # ── Mode dispatch ──────────────────────────────────────────────────

  defp evaluate_topology(%{topology_check: "disabled"} = state), do: state
  defp evaluate_topology(%{topology_settled: true} = state), do: state

  defp evaluate_topology(%{topology_check: "explicit", expected_agents: expected} = state)
       when is_integer(expected) do
    connected = count_connected_agents(state)

    if connected >= expected do
      do_evaluate_assignability(%{state | topology_settled: true})
    else
      state
    end
  end

  defp evaluate_topology(%{topology_check: "infer"} = state) do
    if state.topology_timer, do: Process.cancel_timer(state.topology_timer)

    timer = Process.send_after(self(), :topology_stabilized, @topology_stabilization_ms)
    %{state | topology_timer: timer}
  end

  defp evaluate_topology(state), do: state

  # ── Assignability evaluation ───────────────────────────────────────

  defp do_evaluate_assignability(state) do
    if not function_exported?(state.plugin, :evaluate_assignability, 2) do
      state
    else
      connected_agents = list_agents(state)

      frontier_tasks =
        state.frontier
        |> MapSet.to_list()
        |> Enum.map(fn task_id -> state.tasks[task_id] end)

      case state.plugin.evaluate_assignability(frontier_tasks, connected_agents) do
        {_assignable, []} ->
          state

        {_assignable, unassignable} ->
          new_state = fail_unassignable_tasks(state, unassignable)
          maybe_broadcast_run_complete(new_state)
          new_state
      end
    end
  end

  # ── Failure handling ───────────────────────────────────────────────

  defp fail_unassignable_tasks(state, unassignable) do
    Enum.each(unassignable, fn task ->
      Logger.warning(
        "Task #{task.task_id} failed: no connected agent satisfies requirements #{inspect(task.requirements)}"
      )
    end)

    Enum.reduce(unassignable, state, fn task, acc ->
      updated_task = %{acc.tasks[task.task_id] | status: :failed, exit_code: -1}
      tasks = Map.put(acc.tasks, task.task_id, updated_task)
      frontier = MapSet.delete(acc.frontier, task.task_id)

      tasks =
        case acc.failure_strategy do
          :continue_all -> tasks
          :fail_fast -> DxCore.Core.Scheduler.skip_all_pending(tasks)
        end

      %{
        acc
        | tasks: tasks,
          frontier: frontier,
          failed_fast: acc.failed_fast || acc.failure_strategy == :fail_fast
      }
    end)
  end

  defp maybe_broadcast_run_complete(state) do
    run_status = DxCore.Core.Scheduler.compute_run_status(state.tasks, state.failed_fast)
    endpoint = state.context[:endpoint]
    dispatcher_topic = state.context[:dispatcher_topic]

    if run_status in [:complete, :failed] and endpoint != nil and dispatcher_topic != nil do
      payload = %{
        "run_id" => state.run_id,
        "status" => to_string(run_status),
        "summary" => nil
      }

      case endpoint.broadcast(dispatcher_topic, "run_complete", payload) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.error("Failed to broadcast run_complete for #{state.run_id}: #{inspect(reason)}")
      end
    end
  end

  # ── Agent enumeration ──────────────────────────────────────────────

  defp list_agents(state) do
    case Map.get(state.context, :agent_lister) do
      nil -> []
      fun when is_function(fun, 1) -> fun.(state)
    end
  end

  defp count_connected_agents(state), do: length(list_agents(state))
end
