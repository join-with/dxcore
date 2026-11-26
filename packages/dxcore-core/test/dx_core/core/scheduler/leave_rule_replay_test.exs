defmodule DxCore.Core.Scheduler.LeaveRuleReplayTest do
  # Replays a recorded CI run through `LeaveRule` (spec test 4). The fixture
  # (test/fixtures/replay_ci_run_45796530258.json, its `source` says how it
  # was made) holds the run's executed tasks with their real durations and
  # dependencies, and its 8 agents with their tags and join times.
  #
  # The replay hands tasks out the way the scheduler does: an idle agent
  # takes a ready task that fits it, here the one the real run started
  # first. It runs the same run twice, without the rule (every agent stays
  # until the last task ends, as today) and with it (an agent that gets no
  # task asks `LeaveRule.decide/2` and leaves on `:leave`), and pins what the
  # rule changes: each agent's leave moment, the agent time saved, and how
  # much longer the run gets.
  use ExUnit.Case, async: true

  alias DxCore.Core.AgentInfo
  alias DxCore.Core.Scheduler.LeaveRule
  alias DxCore.Core.Scheduler.Requirements

  @fixture Path.expand("../../../fixtures/replay_ci_run_45796530258.json", __DIR__)

  setup_all do
    run = @fixture |> File.read!() |> Jason.decode!()
    # Fail closed: the replay below proves nothing on an empty fixture.
    assert length(run["tasks"]) == 83
    assert length(run["agents"]) == 8
    %{run: run}
  end

  test "without the rule every agent holds its place to the run's end", %{run: run} do
    result = replay(run, false)

    assert result.unfinished == []
    # The recorded run's last task ended at 1_528_696 ms; the replay's own
    # hand-out order lands within half a second of it.
    assert result.run_end_ms == 1_528_335
    assert Enum.all?(result.left_ms, fn {_agent, at} -> at == result.run_end_ms end)
  end

  test "with the rule, agents leave once the run has no more work for them", %{run: run} do
    without = replay(run, false)
    with_rule = replay(run, true)

    assert with_rule.unfinished == []

    # Each agent's leave moment (ms from the first agent's join). Five leave
    # about 5 minutes before the end, as the recorded run's agents sat idle
    # for 4.7 to 5.3 minutes. Only an idle agent counts as a spare, so
    # agent-8 stays to the end next to agent-2, and agent-4 leaves about
    # 1.9 minutes before the end.
    assert with_rule.left_ms == %{
             "agent-1" => 1_214_534,
             "agent-2" => 1_528_335,
             "agent-3" => 1_249_307,
             "agent-4" => 1_416_867,
             "agent-5" => 1_213_006,
             "agent-6" => 1_213_153,
             "agent-7" => 1_213_841,
             "agent-8" => 1_528_335
           }

    # 1_649_302 ms: 27.5 agent-minutes of box room handed back in this run.
    saved_ms = held_ms(without, run) - held_ms(with_rule, run)
    assert saved_ms == 1_649_302

    # The run does not end later with fewer agents.
    assert with_rule.run_end_ms - without.run_end_ms == 0
  end

  # ── The replay ─────────────────────────────────────────────────────────

  defp held_ms(result, run) do
    Enum.reduce(run["agents"], 0, fn a, acc ->
      acc + Map.fetch!(result.left_ms, a["agent_id"]) - a["joined_ms"]
    end)
  end

  defp replay(run, rule?) do
    tasks =
      Map.new(run["tasks"], fn t ->
        {t["task_id"],
         %{
           deps: t["dependencies"],
           requirements: t["requirements"],
           duration_ms: t["duration_ms"],
           order: t["started_ms"],
           status: :pending,
           assigned_to: nil
         }}
      end)

    agents =
      Map.new(run["agents"], fn a ->
        {a["agent_id"],
         %{
           info: %AgentInfo{agent_id: a["agent_id"], tags: a["tags"]},
           joined_ms: a["joined_ms"]
         }}
      end)

    state = %{
      now: 0,
      tasks: tasks,
      agents: agents,
      running: %{},
      left: %{},
      rule?: rule?
    }

    state = loop(state)
    run_end = state.now

    left =
      Map.new(agents, fn {id, _} -> {id, Map.get(state.left, id, run_end)} end)

    %{
      run_end_ms: run_end,
      left_ms: left,
      unfinished: for({id, %{status: s}} <- state.tasks, s != :done, do: id)
    }
  end

  # Advance to the next event (an agent joins, a task ends), apply it, then
  # let every idle agent ask for work, in agent id order.
  defp loop(state) do
    state = hand_out(state)

    case next_event_ms(state) do
      nil -> state
      at -> state |> Map.put(:now, at) |> finish_tasks_at(at) |> loop()
    end
  end

  defp next_event_ms(state) do
    ends = for {_task, {_agent, ends_at}} <- state.running, do: ends_at

    joins =
      for {id, a} <- state.agents,
          a.joined_ms > state.now,
          not Map.has_key?(state.left, id),
          do: a.joined_ms

    case ends ++ joins do
      [] -> nil
      times -> Enum.min(times)
    end
  end

  defp finish_tasks_at(state, at) do
    {done, still} = Enum.split_with(state.running, fn {_t, {_a, ends}} -> ends == at end)

    tasks =
      Enum.reduce(done, state.tasks, fn {task_id, _}, acc ->
        Map.update!(acc, task_id, &%{&1 | status: :done})
      end)

    %{state | tasks: tasks, running: Map.new(still)}
  end

  defp hand_out(state) do
    busy = MapSet.new(state.running, fn {_t, {agent, _}} -> agent end)

    state.agents
    |> Enum.filter(fn {id, a} ->
      a.joined_ms <= state.now and not Map.has_key?(state.left, id) and
        not MapSet.member?(busy, id)
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce(state, fn {id, a}, acc -> ask(acc, id, a.info) end)
  end

  defp ask(state, agent_id, info) do
    case pick(state, info) do
      {task_id, task} ->
        %{
          state
          | tasks:
              Map.put(state.tasks, task_id, %{task | status: :running, assigned_to: agent_id}),
            running: Map.put(state.running, task_id, {agent_id, state.now + task.duration_ms})
        }

      nil ->
        if state.rule? and LeaveRule.decide(snapshot(state), agent_id) == :leave,
          do: %{state | left: Map.put(state.left, agent_id, state.now)},
          else: state
    end
  end

  defp pick(state, info) do
    state.tasks
    |> Enum.filter(fn {_id, t} ->
      ready?(state, t) and Requirements.fits?(t.requirements, info.tags)
    end)
    |> Enum.min_by(fn {id, t} -> {t.order, id} end, fn -> nil end)
  end

  defp ready?(state, %{status: :pending, deps: deps}),
    do: Enum.all?(deps, &(state.tasks[&1].status == :done))

  defp ready?(_state, _task), do: false

  # What the scheduler hands `LeaveRule`: the present agents (joined, not
  # gone), every task with whether it is ready.
  defp snapshot(state) do
    %{
      run_status: :running,
      draining: false,
      spare: 1,
      agents:
        for(
          {id, a} <- state.agents,
          a.joined_ms <= state.now,
          not Map.has_key?(state.left, id),
          do: a.info
        ),
      tasks:
        for {id, t} <- state.tasks do
          %{
            task_id: id,
            status: t.status,
            requirements: t.requirements,
            assigned_to: t.assigned_to,
            ready?: ready?(state, t)
          }
        end
    }
  end
end
