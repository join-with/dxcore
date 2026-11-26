defmodule DxCore.Core.Scheduler.LeaveRuleTest do
  use ExUnit.Case, async: true

  alias DxCore.Core.AgentInfo
  alias DxCore.Core.Scheduler.LeaveRule

  @e2e %{"e2e" => "true"}

  defp agent(id, tags \\ %{}), do: %AgentInfo{agent_id: id, tags: tags}

  defp task(id, status, opts \\ []) do
    %{
      task_id: id,
      status: status,
      requirements: Keyword.get(opts, :requirements, %{}),
      assigned_to: Keyword.get(opts, :assigned_to),
      ready?: Keyword.get(opts, :ready?, false)
    }
  end

  defp snapshot(tasks, agents, overrides \\ %{}) do
    Map.merge(
      %{run_status: :running, draining: false, tasks: tasks, agents: agents, spare: 1},
      overrides
    )
  end

  # Three idle agents, a fourth running the only unfinished task: every
  # clause before the last would say "leave" here unless it applies.
  defp leavable do
    snapshot(
      [task("done", :done), task("t1", :running, assigned_to: "busy")],
      [agent("a"), agent("b"), agent("c"), agent("busy")]
    )
  end

  test "row 6: an idle agent with nothing ready and a spare left leaves" do
    assert LeaveRule.decide(leavable(), "a") == :leave
  end

  test "row 1: a run that is no longer running keeps the agent for session_finished" do
    for status <- [:complete, :failed] do
      assert LeaveRule.decide(%{leavable() | run_status: status}, "a") == {:stay, :run_ending}
    end
  end

  test "row 2: a draining run keeps every agent" do
    assert LeaveRule.decide(%{leavable() | draining: true}, "a") == {:stay, :draining}
  end

  test "row 3: an agent holding a running task stays" do
    assert LeaveRule.decide(leavable(), "busy") == {:stay, :busy}
  end

  test "row 4: a ready task that fits the agent keeps it" do
    s = %{leavable() | tasks: [task("r", :pending, ready?: true) | leavable().tasks]}
    assert LeaveRule.decide(s, "a") == {:stay, :ready_work}
  end

  test "row 5: the last agent that could take a released task stays as the spare" do
    s = snapshot([task("t1", :running, assigned_to: "busy")], [agent("a"), agent("busy")])
    assert LeaveRule.decide(s, "a") == {:stay, :last_fit}
  end

  test "row 5 counts pending tasks too, and the spare is configurable" do
    # The only unfinished task is pending and not ready (its deps still run
    # elsewhere), so only its spare count can keep a.
    s = snapshot([task("t2", :pending)], [agent("a"), agent("b")], %{spare: 2})

    assert LeaveRule.decide(s, "a") == {:stay, :last_fit}
    assert LeaveRule.decide(%{s | spare: 1}, "a") == :leave
    assert LeaveRule.decide(%{s | spare: 0}, "a") == :leave
  end

  test "a busy agent is no spare: one idle agent stays for two busy holders" do
    # Two tasks run on b and d; a and c are idle. A restarted task must start
    # at once, so only an idle agent counts as its spare: a may leave (c is
    # the spare), then c must stay.
    tasks = [task("t1", :running, assigned_to: "b"), task("t2", :running, assigned_to: "d")]
    s = snapshot(tasks, [agent("a"), agent("b"), agent("c"), agent("d")])
    assert LeaveRule.decide(s, "a") == :leave

    s = snapshot(tasks, [agent("b"), agent("c"), agent("d")])
    assert LeaveRule.decide(s, "c") == {:stay, :last_fit}
  end

  test "a ready task beats the spare count (rows 4 and 5 in order)" do
    # Both rows 4 and 5 hold here; row 4 answers first.
    s = snapshot([task("r", :pending, ready?: true)], [agent("a")])
    assert LeaveRule.decide(s, "a") == {:stay, :ready_work}
  end

  test "an untagged agent leaves while e2e tasks are still to come" do
    s =
      snapshot(
        [
          task("e2e-ready", :pending, requirements: @e2e, ready?: true),
          task("e2e-run", :running, requirements: @e2e, assigned_to: "e2e-1")
        ],
        [agent("plain"), agent("e2e-1", @e2e)]
      )

    assert LeaveRule.decide(s, "plain") == :leave
  end

  test "an e2e agent stays for the ready e2e task, and as the e2e spare" do
    ready =
      snapshot(
        [task("e2e-ready", :pending, requirements: @e2e, ready?: true)],
        [agent("plain"), agent("e2e-1", @e2e), agent("e2e-2", @e2e)]
      )

    assert LeaveRule.decide(ready, "e2e-1") == {:stay, :ready_work}

    # The untagged agent cannot take the e2e task, so it is no spare for it.
    spare =
      snapshot(
        [task("e2e-run", :running, requirements: @e2e, assigned_to: "e2e-1")],
        [agent("plain"), agent("e2e-1", @e2e), agent("e2e-2", @e2e)]
      )

    assert LeaveRule.decide(spare, "e2e-2") == {:stay, :last_fit}
  end

  test "finished tasks keep nobody" do
    s = snapshot([task("d", :done), task("f", :failed), task("s", :skipped)], [agent("a")])
    assert LeaveRule.decide(s, "a") == :leave
  end

  test "an agent missing from the snapshot stays, since its tags are unknown" do
    assert LeaveRule.decide(leavable(), "ghost") == {:stay, :unknown_agent}
  end
end
