defmodule DxCore.Agents.Web.AgentCompletionWakeTest do
  use DxCore.Agents.Web.ChannelCase

  alias DxCore.Agents.{TaskGraph, Scheduler, Sessions, Scope}

  @fixtures_dir Path.join([__DIR__, "..", "..", "..", "..", "fixtures"])

  setup do
    scope = Scope.for_tenant("test-tenant", "Test Corp")
    {:ok, session_id} = Sessions.create_session(scope)

    json = File.read!(Path.join(@fixtures_dir, "dry_run_simple.json"))
    {:ok, graph} = TaskGraph.parse(json)

    {:ok, scheduler} =
      Scheduler.start_link(
        graph: graph,
        run_id: "test-run",
        session_id: session_id,
        plugin: DxCore.Core.Scheduler.NullPlugin
      )

    on_exit(fn ->
      try do
        if Process.alive?(scheduler), do: GenServer.stop(scheduler)
      catch
        :exit, _ -> :ok
      end
    end)

    %{scheduler: scheduler, session_id: session_id, scope: scope}
  end

  defp join_agent(session_id, scope, user_id) do
    {:ok, _, socket} =
      DxCore.Agents.Web.AgentSocket
      |> socket(user_id, %{current_scope: scope})
      |> subscribe_and_join(DxCore.Agents.Web.AgentChannel, "agent:#{session_id}")

    socket
  end

  test "completion broadcasts tasks_available with the scheduler hint while the run continues",
       %{session_id: session_id, scope: scope} do
    socket = join_agent(session_id, scope, "user_1")
    push(socket, "agent_ready", %{"agent_id" => "agent-1"})
    assert_push "assign_task", %{"task_id" => "@repo/ui#build"}

    DxCore.Agents.Web.Endpoint.subscribe("agent:#{session_id}")

    # Completing @repo/ui#build unlocks admin#build + api#build (run continues).
    push(socket, "task_result", %{"task_id" => "@repo/ui#build", "exit_code" => 0})

    assert_receive %Phoenix.Socket.Broadcast{
                     topic: "agent:" <> _,
                     event: "tasks_available",
                     payload: %{scheduler_pid: pid, run_id: _}
                   },
                   1000

    assert is_pid(pid)
  end

  test "an idle agent is woken and assigned newly-unlocked work after another agent completes",
       %{session_id: session_id, scope: scope} do
    # agent-1 takes the only ready task (@repo/ui#build).
    socket1 = join_agent(session_id, scope, "user_1")
    push(socket1, "agent_ready", %{"agent_id" => "agent-1"})
    assert_push "assign_task", %{"task_id" => "@repo/ui#build"}

    # agent-2 connects while nothing else is ready -> goes idle (no assignment).
    socket2 = join_agent(session_id, scope, "user_2")
    push(socket2, "agent_ready", %{"agent_id" => "agent-2"})
    refute_push "assign_task", %{"task_id" => _}, 300

    # agent-1 completes @repo/ui#build, unlocking admin#build + api#build.
    push(socket1, "task_result", %{"task_id" => "@repo/ui#build", "exit_code" => 0})

    # With the fix, BOTH agents are assigned: agent-1 self-assigns one task and
    # the woken agent-2 takes the other -> two assign_task pushes to the test pid.
    # Without the fix, agent-2 is never woken and only one push arrives.
    assert_push "assign_task", %{"task_id" => first}, 1000
    assert_push "assign_task", %{"task_id" => second}, 1000
    assert Enum.sort([first, second]) == ["admin#build", "api#build"]
  end
end
