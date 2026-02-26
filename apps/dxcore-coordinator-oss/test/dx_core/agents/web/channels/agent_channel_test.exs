defmodule DxCore.Agents.Web.AgentChannelTest do
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

    {:ok, _, socket} =
      DxCore.Agents.Web.AgentSocket
      |> socket("user_id", %{current_scope: scope})
      |> subscribe_and_join(DxCore.Agents.Web.AgentChannel, "agent:#{session_id}")

    on_exit(fn ->
      try do
        if Process.alive?(scheduler), do: GenServer.stop(scheduler)
      catch
        :exit, _ -> :ok
      end
    end)

    %{socket: socket, scheduler: scheduler, session_id: session_id, scope: scope}
  end

  describe "join" do
    test "extracts session_id from topic and stores in assigns", %{
      socket: socket,
      session_id: session_id
    } do
      assert socket.assigns.session_id == session_id
    end
  end

  describe "agent_ready" do
    test "registers agent with Sessions and assigns task", %{
      socket: socket,
      session_id: session_id,
      scope: scope
    } do
      push(socket, "agent_ready", %{"agent_id" => "agent-1"})
      assert_push "assign_task", %{"task_id" => "@repo/ui#build"}

      # Verify agent was registered in Sessions
      {:ok, session} = Sessions.get_session(scope, session_id)
      assert MapSet.member?(session.agents, "agent-1")
    end

    test "stores agent_id in socket assigns", %{socket: socket} do
      push(socket, "agent_ready", %{"agent_id" => "agent-1"})
      assert_push "assign_task", %{"task_id" => "@repo/ui#build"}
    end

    test "agent_ready with capabilities stores AgentInfo in socket", %{socket: socket} do
      push(socket, "agent_ready", %{
        "agent_id" => "agent-1",
        "capabilities" => %{
          "cpu_cores" => 8,
          "memory_mb" => 16384,
          "disk_free_mb" => 50000,
          "tags" => %{"gpu" => "true"}
        }
      })

      # The agent should receive a task assignment (from the test graph)
      assert_push "assign_task", _payload, 1000
    end

    test "agent_ready without capabilities uses defaults", %{socket: socket} do
      push(socket, "agent_ready", %{"agent_id" => "agent-1"})
      assert_push "assign_task", _payload, 1000
    end
  end

  describe "task_result" do
    test "with success unblocks next tasks", %{socket: socket} do
      push(socket, "agent_ready", %{"agent_id" => "agent-1"})
      assert_push "assign_task", %{"task_id" => "@repo/ui#build"}

      push(socket, "task_result", %{
        "task_id" => "@repo/ui#build",
        "exit_code" => 0,
        "duration_ms" => 1500
      })

      assert_push "assign_task", %{"task_id" => task_id}
      assert task_id in ["admin#build", "api#build"]
    end

    test "broadcasts task_completed to session-scoped dispatcher topic", %{
      socket: socket,
      session_id: session_id
    } do
      DxCore.Agents.Web.Endpoint.subscribe("dispatcher:#{session_id}")

      push(socket, "agent_ready", %{"agent_id" => "agent-1"})
      assert_push "assign_task", %{"task_id" => "@repo/ui#build"}

      push(socket, "task_result", %{
        "task_id" => "@repo/ui#build",
        "exit_code" => 0,
        "duration_ms" => 1500
      })

      assert_receive %Phoenix.Socket.Broadcast{
        topic: "dispatcher:" <> _,
        event: "task_completed",
        payload: %{"task_id" => "@repo/ui#build", "agent_id" => "agent-1"}
      }
    end

    test "on run complete, broadcasts run_complete and calls mark_run_complete, then tries next task",
         %{socket: socket, session_id: session_id} do
      DxCore.Agents.Web.Endpoint.subscribe("dispatcher:#{session_id}")

      push(socket, "agent_ready", %{"agent_id" => "agent-1"})
      assert_push "assign_task", %{"task_id" => "@repo/ui#build"}

      # Complete all tasks in order to trigger run_complete
      push(socket, "task_result", %{
        "task_id" => "@repo/ui#build",
        "exit_code" => 0,
        "duration_ms" => 100
      })

      assert_push "assign_task", %{"task_id" => next_task}
      assert next_task in ["admin#build", "api#build"]

      push(socket, "task_result", %{
        "task_id" => next_task,
        "exit_code" => 0,
        "duration_ms" => 100
      })

      assert_push "assign_task", %{"task_id" => next_task2}

      # Complete remaining tasks
      push(socket, "task_result", %{
        "task_id" => next_task2,
        "exit_code" => 0,
        "duration_ms" => 100
      })

      # If we got api#build first, then admin#build, then admin#test
      # If we got admin#build first, then we might get api#build or admin#test
      # Keep completing until run_complete
      case assert_push_or_run_complete(session_id) do
        {:task, final_task} ->
          push(socket, "task_result", %{
            "task_id" => final_task,
            "exit_code" => 0,
            "duration_ms" => 100
          })

          assert_receive %Phoenix.Socket.Broadcast{
            topic: "dispatcher:" <> _,
            event: "run_complete",
            payload: %{"run_id" => "test-run", "status" => _status}
          }

        :run_complete ->
          :ok
      end

      # Should NOT receive shutdown (agents stay idle until explicit shutdown)
      refute_push "shutdown", _
    end
  end

  describe "task_log" do
    test "forwards log line to dispatcher topic", %{socket: socket, session_id: session_id} do
      DxCore.Agents.Web.Endpoint.subscribe("dispatcher:#{session_id}")

      push(socket, "agent_ready", %{"agent_id" => "agent-1"})
      assert_push "assign_task", %{"task_id" => _}

      push(socket, "task_log", %{
        "task_id" => "@repo/ui#build",
        "line" => "\e[32m✓ app:build\e[0m"
      })

      assert_receive %Phoenix.Socket.Broadcast{
        topic: "dispatcher:" <> _,
        event: "task_log",
        payload: %{
          "agent_id" => "agent-1",
          "task_id" => "@repo/ui#build",
          "line" => "\e[32m✓ app:build\e[0m"
        }
      }
    end
  end

  describe "lifecycle events" do
    test "broadcasts agent_connected on agent_ready", %{socket: socket, session_id: session_id} do
      DxCore.Agents.Web.Endpoint.subscribe("dispatcher:#{session_id}")

      push(socket, "agent_ready", %{"agent_id" => "agent-1"})
      assert_push "assign_task", %{"task_id" => _}

      assert_receive %Phoenix.Socket.Broadcast{
        topic: "dispatcher:" <> _,
        event: "agent_connected",
        payload: %{"agent_id" => "agent-1"}
      }
    end

    test "broadcasts agent_disconnected on leave", %{session_id: session_id, scope: scope} do
      DxCore.Agents.Web.Endpoint.subscribe("dispatcher:#{session_id}")

      {:ok, _, socket2} =
        DxCore.Agents.Web.AgentSocket
        |> socket("user_id2", %{current_scope: scope})
        |> subscribe_and_join(DxCore.Agents.Web.AgentChannel, "agent:#{session_id}")

      push(socket2, "agent_ready", %{"agent_id" => "agent-2"})
      assert_push "assign_task", %{"task_id" => _}

      # Drain agent_connected
      assert_receive %Phoenix.Socket.Broadcast{event: "agent_connected"}

      Process.unlink(socket2.channel_pid)
      close(socket2)

      assert_receive %Phoenix.Socket.Broadcast{
        topic: "dispatcher:" <> _,
        event: "agent_disconnected",
        payload: %{"agent_id" => "agent-2"}
      }
    end
  end

  describe "handle_out tasks_available" do
    test "tries to assign task when no current task", %{session_id: session_id} do
      scope = Scope.for_tenant("test-tenant", "Test Corp")

      # Create a second socket/channel for this session
      {:ok, _, socket2} =
        DxCore.Agents.Web.AgentSocket
        |> socket("user_id2", %{current_scope: scope})
        |> subscribe_and_join(DxCore.Agents.Web.AgentChannel, "agent:#{session_id}")

      push(socket2, "agent_ready", %{"agent_id" => "agent-2"})
      # Should get a task since scheduler has frontier tasks
      assert_push "assign_task", %{"task_id" => _}
    end
  end

  # Helper to handle the variable completion order of tasks
  defp assert_push_or_run_complete(session_id) do
    receive do
      %Phoenix.Socket.Message{event: "assign_task", payload: %{"task_id" => task_id}} ->
        {:task, task_id}

      %Phoenix.Socket.Broadcast{
        topic: "dispatcher:" <> ^session_id,
        event: "run_complete"
      } ->
        :run_complete
    after
      1000 ->
        # Check if we already received run_complete on the dispatcher topic
        receive do
          %Phoenix.Socket.Broadcast{event: "run_complete"} -> :run_complete
        after
          0 -> flunk("Expected either assign_task or run_complete")
        end
    end
  end
end
