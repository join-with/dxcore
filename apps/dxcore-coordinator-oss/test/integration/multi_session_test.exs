defmodule DxCore.Agents.Integration.MultiSessionTest do
  @moduledoc """
  Integration test that verifies two sessions running concurrently are
  completely isolated: separate dispatchers, separate agents, separate
  scheduler instances. Tasks from session A must not leak to session B.
  """

  use DxCore.Agents.Web.ChannelCase

  alias DxCore.Agents.{Scope, Sessions}

  @fixtures_dir Path.join([__DIR__, "..", "fixtures"])

  test "two sessions run independently without task leakage" do
    scope = Scope.for_tenant("multi-tenant", "Multi Corp")
    {:ok, session_a} = Sessions.create_session(scope)
    {:ok, session_b} = Sessions.create_session(scope)

    # ── 1. Start dispatchers for both sessions ──────────────────────────
    {:ok, _, disp_a} =
      DxCore.Agents.Web.DispatcherSocket
      |> socket("user_id", %{current_scope: scope})
      |> subscribe_and_join(DxCore.Agents.Web.DispatcherChannel, "dispatcher:#{session_a}")

    {:ok, _, disp_b} =
      DxCore.Agents.Web.DispatcherSocket
      |> socket("user_id", %{current_scope: scope})
      |> subscribe_and_join(DxCore.Agents.Web.DispatcherChannel, "dispatcher:#{session_b}")

    # ── 2. Submit the same graph to both sessions ───────────────────────
    json = File.read!(Path.join(@fixtures_dir, "dry_run_simple.json"))
    {:ok, parsed} = Jason.decode(json)

    ref_a = push(disp_a, "submit_graph", %{"run_id" => "run-a", "tasks" => parsed["tasks"]})
    assert_reply ref_a, :ok, %{"total_tasks" => 4}

    ref_b = push(disp_b, "submit_graph", %{"run_id" => "run-b", "tasks" => parsed["tasks"]})
    assert_reply ref_b, :ok, %{"total_tasks" => 4}

    # ── 3. Connect agents to each session ───────────────────────────────
    {:ok, _, agent_a} =
      DxCore.Agents.Web.AgentSocket
      |> socket("agent_a", %{current_scope: scope})
      |> subscribe_and_join(DxCore.Agents.Web.AgentChannel, "agent:#{session_a}")

    {:ok, _, agent_b} =
      DxCore.Agents.Web.AgentSocket
      |> socket("agent_b", %{current_scope: scope})
      |> subscribe_and_join(DxCore.Agents.Web.AgentChannel, "agent:#{session_b}")

    # ── 4. Both agents announce ready ───────────────────────────────────
    push(agent_a, "agent_ready", %{"agent_id" => "agent-a"})
    push(agent_b, "agent_ready", %{"agent_id" => "agent-b"})

    # Both should receive an assign_task push (the root task @repo/ui#build
    # from their respective graphs). Since both pushes go to the test process
    # mailbox, we just assert we get two assign_task messages.
    assert_push "assign_task", %{"task_id" => "@repo/ui#build"}, 1_000
    assert_push "assign_task", %{"task_id" => "@repo/ui#build"}, 1_000

    # ── 5. Key assertion: schedulers are separate processes ─────────────
    scheduler_pids_a = Sessions.get_scheduler_pids(session_a)
    scheduler_pids_b = Sessions.get_scheduler_pids(session_b)

    assert [{pid_a, "run-a"}] = scheduler_pids_a
    assert [{pid_b, "run-b"}] = scheduler_pids_b
    assert pid_a != pid_b

    # ── 6. Verify scheduler status is session-scoped ────────────────────
    status_a = DxCore.Agents.Scheduler.status(pid_a)
    status_b = DxCore.Agents.Scheduler.status(pid_b)
    assert status_a.run_id == "run-a"
    assert status_b.run_id == "run-b"

    # ── 7. Complete a task in session A; session B is unaffected ─────────
    push(agent_a, "task_result", %{
      "task_id" => "@repo/ui#build",
      "exit_code" => 0,
      "duration_ms" => 100
    })

    # Agent A gets a new task (from session A's graph)
    assert_push "assign_task", %{"task_id" => next_a}, 1_000
    assert next_a in ["admin#build", "api#build"]

    # Session B's scheduler should still have @repo/ui#build as running
    status_b_after = DxCore.Agents.Scheduler.status(pid_b)
    ui_build_b = status_b_after.tasks["@repo/ui#build"]
    assert ui_build_b.status == :running

    # ── 8. Clean up ─────────────────────────────────────────────────────
    leave(disp_a)
    leave(disp_b)
    leave(agent_a)
    leave(agent_b)
  end
end
