defmodule DxCore.Agents.Integration.RoundTripTest do
  @moduledoc """
  Integration test that exercises the full task-execution cycle through
  Phoenix Channels: submit a graph via the dispatcher channel, assign
  tasks to an agent channel in dependency order, complete them, and verify
  the run_complete signal.

  Uses the `dry_run_simple.json` fixture whose DAG is:

      @repo/ui#build  (no deps)
      +-- admin#build (deps: @repo/ui#build)
      |   +-- admin#test (deps: admin#build)
      +-- api#build   (deps: @repo/ui#build)
  """

  use DxCore.Agents.Web.ChannelCase

  alias DxCore.Agents.{Scope, Sessions}

  @fixtures_dir Path.join([__DIR__, "..", "fixtures"])

  setup do
    :ok
  end

  test "full round-trip: submit graph, assign tasks, complete run" do
    scope = Scope.for_tenant("integration-tenant", "Integration Corp")
    {:ok, session_id} = Sessions.create_session(scope)

    # ── 1. Dispatcher submits the task graph ──────────────────────────
    {:ok, _, dispatcher_socket} =
      DxCore.Agents.Web.DispatcherSocket
      |> socket("user_id", %{current_scope: scope})
      |> subscribe_and_join(DxCore.Agents.Web.DispatcherChannel, "dispatcher:#{session_id}")

    json = File.read!(Path.join(@fixtures_dir, "dry_run_simple.json"))
    {:ok, parsed} = Jason.decode(json)

    ref =
      push(dispatcher_socket, "submit_graph", %{
        "run_id" => "integration-test",
        "tasks" => parsed["tasks"]
      })

    assert_reply ref, :ok, %{"total_tasks" => 4}

    # ── 2. Agent connects to session-scoped topic and gets first task ──
    {:ok, _, agent_socket} =
      DxCore.Agents.Web.AgentSocket
      |> socket("agent_user_1", %{current_scope: scope})
      |> subscribe_and_join(DxCore.Agents.Web.AgentChannel, "agent:#{session_id}")

    push(agent_socket, "agent_ready", %{"agent_id" => "agent-1"})
    assert_push "assign_task", %{"task_id" => "@repo/ui#build"}, 1_000

    # ── 3. Complete @repo/ui#build -> unblocks admin#build + api#build ──
    push(agent_socket, "task_result", %{
      "task_id" => "@repo/ui#build",
      "exit_code" => 0,
      "duration_ms" => 100
    })

    assert_push "assign_task", %{"task_id" => next_task}, 1_000
    assert next_task in ["admin#build", "api#build"]

    # ── 4. Complete second task -> may unblock admin#test ──
    push(agent_socket, "task_result", %{
      "task_id" => next_task,
      "exit_code" => 0,
      "duration_ms" => 200
    })

    assert_push "assign_task", %{"task_id" => next_task2}, 1_000

    # Subscribe to dispatcher topic before completing remaining tasks
    # so we don't miss the run_complete broadcast
    DxCore.Agents.Web.Endpoint.subscribe("dispatcher:#{session_id}")

    # ── 5. Complete third task ──
    push(agent_socket, "task_result", %{
      "task_id" => next_task2,
      "exit_code" => 0,
      "duration_ms" => 150
    })

    # If there's a fourth task (admin#test), complete it too
    case receive_optional_push(1_000) do
      {:ok, %{"task_id" => final_task}} ->
        push(agent_socket, "task_result", %{
          "task_id" => final_task,
          "exit_code" => 0,
          "duration_ms" => 300
        })

      :none ->
        :ok
    end

    # The dispatcher should have received run_complete broadcast on session topic.
    assert_receive %Phoenix.Socket.Broadcast{
                     topic: "dispatcher:" <> _,
                     event: "run_complete",
                     payload: %{"run_id" => "integration-test", "status" => "complete"}
                   },
                   1_000

    # Should NOT receive shutdown (session-scoped: no shutdown on run_complete)
    refute_push "shutdown", _, 200
  end

  defp receive_optional_push(timeout) do
    receive do
      %Phoenix.Socket.Message{event: "assign_task", payload: payload} ->
        {:ok, payload}
    after
      timeout -> :none
    end
  end
end
