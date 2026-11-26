defmodule DxCore.Core.Scheduler.LeaveRule do
  @moduledoc """
  Whether an idle agent may leave its run now (#18809, spec
  `docs/superpowers/specs/2026-11-26-ci-agent-early-release-design.md`).

  A pure function of a snapshot of the run: no processes, no clock, no I/O.
  `DxCore.Core.Scheduler` builds the snapshot inside its `request_task` call,
  so the answer and the task assignment it races with are serialized.

  The clauses run in order and the first match wins:

  1. the run is no longer `:running` → `{:stay, :run_ending}` (the session's
     own `session_finished` shutdown ends the agent);
  2. the run is draining → `{:stay, :draining}`;
  3. the agent holds a `:running` task → `{:stay, :busy}`;
  4. a ready task fits the agent → `{:stay, :ready_work}`;
  5. some unfinished task (pending or running) that fits the agent has fewer
     than `spare` other IDLE fitting agents → `{:stay, :last_fit}`, a spare
     that starts a released task at once. An agent holding a `:running` task
     (the task's own holder or any other) is no spare: it would start the
     task only after its own ends;
  6. otherwise → `:leave`.

  Tasks the agent does not fit never keep it. "Fits" is
  `DxCore.Core.Scheduler.Requirements.fits?/2`. An agent missing from
  `agents` (its own entry is how its tags are known) stays:
  `{:stay, :unknown_agent}`.
  """

  alias DxCore.Core.AgentInfo
  alias DxCore.Core.Scheduler.Requirements

  @type task :: %{
          task_id: String.t(),
          status: :pending | :running | :done | :failed | :skipped,
          requirements: map(),
          assigned_to: String.t() | nil,
          ready?: boolean()
        }

  @type snapshot :: %{
          run_status: :running | :complete | :failed,
          draining: boolean(),
          tasks: [task()],
          agents: [AgentInfo.t()],
          spare: non_neg_integer()
        }

  @type reason :: :run_ending | :draining | :busy | :ready_work | :last_fit | :unknown_agent

  @spec decide(snapshot(), String.t()) :: :leave | {:stay, reason()}
  def decide(%{run_status: status}, _agent_id) when status != :running,
    do: {:stay, :run_ending}

  def decide(%{draining: true}, _agent_id), do: {:stay, :draining}

  def decide(%{tasks: tasks, agents: agents, spare: spare}, agent_id)
      when is_integer(spare) and spare >= 0 do
    case Enum.find(agents, &(&1.agent_id == agent_id)) do
      nil -> {:stay, :unknown_agent}
      %AgentInfo{tags: tags} -> decide_for(tasks, agents, spare, agent_id, tags)
    end
  end

  defp decide_for(tasks, agents, spare, agent_id, tags) do
    idle_others = idle_others(tasks, agents, agent_id)

    cond do
      Enum.any?(tasks, &(&1.status == :running and &1.assigned_to == agent_id)) ->
        {:stay, :busy}

      Enum.any?(tasks, &(&1.ready? and &1.status == :pending and fits?(&1, tags))) ->
        {:stay, :ready_work}

      Enum.any?(tasks, &needs_this_agent?(&1, tags, idle_others, spare)) ->
        {:stay, :last_fit}

      true ->
        :leave
    end
  end

  defp needs_this_agent?(%{status: status} = task, tags, idle_others, spare)
       when status in [:pending, :running] do
    fits?(task, tags) and Enum.count(idle_others, &fits?(task, &1.tags)) < spare
  end

  defp needs_this_agent?(_task, _tags, _idle_others, _spare), do: false

  # The other agents that hold no running task: the ones that could start a
  # released task at once.
  defp idle_others(tasks, agents, agent_id) do
    busy = for %{status: :running, assigned_to: holder} <- tasks, into: MapSet.new(), do: holder
    Enum.reject(agents, &(&1.agent_id == agent_id or MapSet.member?(busy, &1.agent_id)))
  end

  defp fits?(task, tags), do: Requirements.fits?(task.requirements, tags)
end
