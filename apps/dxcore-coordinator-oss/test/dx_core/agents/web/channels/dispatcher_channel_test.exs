defmodule DxCore.Agents.Web.DispatcherChannelTest do
  use DxCore.Agents.Web.ChannelCase

  alias DxCore.Agents.{Scheduler, Sessions, Scope}

  @fixtures_dir Path.join([__DIR__, "..", "..", "..", "..", "fixtures"])

  setup do
    scope = Scope.for_tenant("test-tenant", "Test Corp")
    {:ok, session_id} = Sessions.create_session(scope)

    {:ok, _, socket} =
      DxCore.Agents.Web.DispatcherSocket
      |> socket("user_id", %{current_scope: scope})
      |> subscribe_and_join(DxCore.Agents.Web.DispatcherChannel, "dispatcher:#{session_id}")

    on_exit(fn ->
      # Clean up schedulers for this session
      for {pid, _run_id} <- Sessions.get_scheduler_pids(session_id) do
        try do
          DynamicSupervisor.terminate_child(DxCore.Core.SchedulerSupervisor, pid)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    %{socket: socket, session_id: session_id, scope: scope}
  end

  describe "join" do
    test "extracts session_id from topic and stores in assigns", %{
      socket: socket,
      session_id: session_id
    } do
      assert socket.assigns.session_id == session_id
    end

    test "has current_scope in assigns from socket auth", %{socket: socket, scope: scope} do
      assert socket.assigns.current_scope == scope
    end
  end

  describe "submit_graph" do
    test "starts scheduler and replies with run info", %{socket: socket} do
      json = File.read!(Path.join(@fixtures_dir, "dry_run_simple.json"))
      {:ok, parsed} = Jason.decode(json)

      ref =
        push(socket, "submit_graph", %{
          "run_id" => "test-run",
          "tasks" => parsed["tasks"]
        })

      assert_reply ref, :ok, %{
        "run_id" => "test-run",
        "total_tasks" => 4,
        "cached_tasks" => 0
      }
    end

    test "with cache hits reports cached count", %{socket: socket} do
      json = File.read!(Path.join(@fixtures_dir, "dry_run_with_cache_hits.json"))
      {:ok, parsed} = Jason.decode(json)

      ref =
        push(socket, "submit_graph", %{
          "run_id" => "test-run",
          "tasks" => parsed["tasks"]
        })

      assert_reply ref, :ok, %{
        "run_id" => "test-run",
        "total_tasks" => 4,
        "cached_tasks" => 1
      }
    end

    test "registers run with Sessions", %{socket: socket, session_id: session_id, scope: scope} do
      json = File.read!(Path.join(@fixtures_dir, "dry_run_simple.json"))
      {:ok, parsed} = Jason.decode(json)

      ref =
        push(socket, "submit_graph", %{
          "run_id" => "test-run",
          "tasks" => parsed["tasks"]
        })

      assert_reply ref, :ok, _

      # Verify the run was registered in Sessions
      {:ok, session} = Sessions.get_session(scope, session_id)
      assert MapSet.member?(session.run_ids, "test-run")
    end

    test "starts scheduler under DynamicSupervisor", %{
      socket: socket,
      session_id: session_id
    } do
      json = File.read!(Path.join(@fixtures_dir, "dry_run_simple.json"))
      {:ok, parsed} = Jason.decode(json)

      ref =
        push(socket, "submit_graph", %{
          "run_id" => "test-run",
          "tasks" => parsed["tasks"]
        })

      assert_reply ref, :ok, _

      # Verify scheduler is alive and registered
      pid = Scheduler.whereis(session_id, "test-run")
      assert pid != nil
      assert Process.alive?(pid)

      # Verify it's supervised by DynamicSupervisor
      children = DynamicSupervisor.which_children(DxCore.Core.SchedulerSupervisor)
      child_pids = Enum.map(children, fn {_, pid, _, _} -> pid end)
      assert pid in child_pids
    end

    test "broadcasts tasks_available to session-scoped agent topic", %{
      socket: socket,
      session_id: session_id
    } do
      DxCore.Agents.Web.Endpoint.subscribe("agent:#{session_id}")

      json = File.read!(Path.join(@fixtures_dir, "dry_run_simple.json"))
      {:ok, parsed} = Jason.decode(json)

      ref =
        push(socket, "submit_graph", %{
          "run_id" => "test-run",
          "tasks" => parsed["tasks"]
        })

      assert_reply ref, :ok, _

      assert_receive %Phoenix.Socket.Broadcast{
        topic: "agent:" <> ^session_id,
        event: "tasks_available",
        payload: %{}
      }
    end

    test "stops existing scheduler before starting new one for same run_id", %{
      socket: socket,
      session_id: session_id
    } do
      json = File.read!(Path.join(@fixtures_dir, "dry_run_simple.json"))
      {:ok, parsed} = Jason.decode(json)

      # Submit first graph
      ref1 =
        push(socket, "submit_graph", %{
          "run_id" => "test-run",
          "tasks" => parsed["tasks"]
        })

      assert_reply ref1, :ok, _

      first_pid = Scheduler.whereis(session_id, "test-run")
      assert first_pid != nil

      # Submit again with same run_id - should replace
      ref2 =
        push(socket, "submit_graph", %{
          "run_id" => "test-run",
          "tasks" => parsed["tasks"]
        })

      assert_reply ref2, :ok, _

      second_pid = Scheduler.whereis(session_id, "test-run")
      assert second_pid != nil
      assert second_pid != first_pid
    end
  end

  describe "cancel_run" do
    test "terminates running scheduler via DynamicSupervisor", %{
      socket: socket,
      session_id: session_id
    } do
      json = File.read!(Path.join(@fixtures_dir, "dry_run_simple.json"))
      {:ok, parsed} = Jason.decode(json)

      # Start a scheduler first
      ref =
        push(socket, "submit_graph", %{
          "run_id" => "test-run",
          "tasks" => parsed["tasks"]
        })

      assert_reply ref, :ok, _

      pid = Scheduler.whereis(session_id, "test-run")
      assert pid != nil
      assert Process.alive?(pid)

      # Cancel the run
      push(socket, "cancel_run", %{"run_id" => "test-run"})

      # Give it a moment to process
      Process.sleep(50)

      # Verify scheduler is no longer alive
      assert Scheduler.whereis(session_id, "test-run") == nil
    end

    test "handles cancel for non-existent run gracefully", %{socket: socket} do
      # Should not crash
      push(socket, "cancel_run", %{"run_id" => "non-existent-run"})

      # Give it a moment to process - no crash means success
      Process.sleep(50)
    end
  end
end
