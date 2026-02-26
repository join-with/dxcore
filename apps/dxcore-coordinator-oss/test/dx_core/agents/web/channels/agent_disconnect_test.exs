defmodule DxCore.Agents.Web.AgentDisconnectTest do
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

  test "disconnected agent's task returns to frontier", %{
    scheduler: scheduler,
    session_id: session_id,
    scope: scope
  } do
    # Agent 1 connects and gets a task
    {:ok, _, socket} =
      DxCore.Agents.Web.AgentSocket
      |> socket("user_id", %{current_scope: scope})
      |> subscribe_and_join(DxCore.Agents.Web.AgentChannel, "agent:#{session_id}")

    push(socket, "agent_ready", %{"agent_id" => "agent-1"})
    assert_push "assign_task", %{"task_id" => "@repo/ui#build"}

    # Verify task is running
    status = Scheduler.status(scheduler)
    assert status.tasks["@repo/ui#build"].status == :running

    # Simulate disconnect by leaving the channel
    Process.unlink(socket.channel_pid)
    ref = leave(socket)
    assert_reply ref, :ok

    # Give terminate callback time to run
    Process.sleep(100)

    # Task should be back in pending/frontier
    status = Scheduler.status(scheduler)
    assert status.tasks["@repo/ui#build"].status == :pending

    # Another agent can now pick it up
    {:ok, task} = Scheduler.request_task(scheduler, "agent-2")
    assert task.task_id == "@repo/ui#build"
  end

  test "terminate unregisters agent from Sessions", %{
    scheduler: _scheduler,
    session_id: session_id,
    scope: scope
  } do
    {:ok, _, socket} =
      DxCore.Agents.Web.AgentSocket
      |> socket("user_id", %{current_scope: scope})
      |> subscribe_and_join(DxCore.Agents.Web.AgentChannel, "agent:#{session_id}")

    push(socket, "agent_ready", %{"agent_id" => "agent-disconnect-1"})
    assert_push "assign_task", %{"task_id" => _}

    # Verify agent is registered
    {:ok, session} = Sessions.get_session(scope, session_id)
    assert MapSet.member?(session.agents, "agent-disconnect-1")

    # Simulate disconnect
    Process.unlink(socket.channel_pid)
    ref = leave(socket)
    assert_reply ref, :ok

    # Give terminate callback time to run
    Process.sleep(100)

    # Agent should be unregistered from Sessions
    {:ok, session} = Sessions.get_session(scope, session_id)
    refute MapSet.member?(session.agents, "agent-disconnect-1")
  end

  test "terminate broadcasts tasks_available to session topic", %{
    scheduler: _scheduler,
    session_id: session_id,
    scope: scope
  } do
    {:ok, _, socket} =
      DxCore.Agents.Web.AgentSocket
      |> socket("user_id", %{current_scope: scope})
      |> subscribe_and_join(DxCore.Agents.Web.AgentChannel, "agent:#{session_id}")

    push(socket, "agent_ready", %{"agent_id" => "agent-broadcast-1"})
    assert_push "assign_task", %{"task_id" => _}

    # Subscribe to the agent topic to see broadcasts
    DxCore.Agents.Web.Endpoint.subscribe("agent:#{session_id}")

    # Simulate disconnect
    Process.unlink(socket.channel_pid)
    ref = leave(socket)
    assert_reply ref, :ok

    # Should receive tasks_available broadcast on the session topic
    assert_receive %Phoenix.Socket.Broadcast{
                     topic: "agent:" <> _,
                     event: "tasks_available",
                     payload: %{}
                   },
                   1000
  end
end
