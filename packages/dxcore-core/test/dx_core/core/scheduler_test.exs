defmodule DxCore.Core.SchedulerTest do
  use ExUnit.Case, async: true

  alias DxCore.Core.AgentInfo
  alias DxCore.Core.Scheduler
  alias DxCore.Core.TaskGraph

  @fixtures_dir Path.join([__DIR__, "..", "..", "fixtures"])

  defp unique_session_id do
    "test-session-#{System.unique_integer([:positive])}"
  end

  # ── Test plugin that records on_task_complete calls ──────────────────

  defmodule RecordingPlugin do
    @moduledoc false
    @behaviour DxCore.Core.SchedulerPlugin

    @impl true
    def select_task([], _agent, _context), do: nil
    def select_task([first | _], _agent, _context), do: first

    @impl true
    def expand_graph(graph, _context), do: graph

    @impl true
    def on_task_complete(task, result, duration_ms, agent, context) do
      send(context[:test_pid], {:on_task_complete, task.task_id, result, duration_ms, agent})
      :ok
    end
  end

  defmodule CrashingPlugin do
    @moduledoc false
    @behaviour DxCore.Core.SchedulerPlugin

    @impl true
    def select_task([], _agent, _context), do: nil
    def select_task([first | _], _agent, _context), do: first

    @impl true
    def expand_graph(graph, _context), do: graph

    @impl true
    def on_task_complete(_task, _result, _duration_ms, _agent, _context) do
      raise "boom"
    end
  end

  setup do
    # Start the Registry for this test process
    registry_name = DxCore.Core.SchedulerRegistry
    start_supervised!({Registry, keys: :unique, name: registry_name})

    json = File.read!(Path.join(@fixtures_dir, "dry_run_simple.json"))
    {:ok, graph} = TaskGraph.parse(json)
    session_id = unique_session_id()

    {:ok, pid} =
      Scheduler.start_link(
        graph: graph,
        run_id: "test-run-1",
        session_id: session_id,
        plugin: DxCore.Core.Scheduler.NullPlugin
      )

    %{scheduler: pid, session_id: session_id, graph: graph}
  end

  describe "request_task/2" do
    test "assigns frontier task to agent", %{scheduler: pid} do
      assert {:ok, task} = Scheduler.request_task(pid, "agent-1")
      assert task.task_id == "@repo/ui#build"
    end

    test "returns :no_task when frontier is empty and work remains", %{scheduler: pid} do
      {:ok, _} = Scheduler.request_task(pid, "agent-1")
      assert :no_task = Scheduler.request_task(pid, "agent-2")
    end
  end

  describe "report_result/3" do
    test "completing a task unblocks dependents", %{scheduler: pid} do
      {:ok, task} = Scheduler.request_task(pid, "agent-1")
      assert task.task_id == "@repo/ui#build"

      {:ok, _} = Scheduler.report_result(pid, "@repo/ui#build", :success)

      {:ok, task2} = Scheduler.request_task(pid, "agent-1")
      assert task2.task_id in ["admin#build", "api#build"]

      {:ok, task3} = Scheduler.request_task(pid, "agent-2")
      assert task3.task_id in ["admin#build", "api#build"]
      assert task2.task_id != task3.task_id
    end

    test "failing a task propagates failure to dependents", %{scheduler: pid} do
      {:ok, _} = Scheduler.request_task(pid, "agent-1")
      {:ok, _} = Scheduler.report_result(pid, "@repo/ui#build", :failed)

      status = Scheduler.status(pid)
      assert status.tasks["admin#build"].status == :failed
      assert status.tasks["api#build"].status == :failed
      assert status.tasks["admin#test"].status == :failed
    end
  end

  describe "report_result returns run_status atomically" do
    test "returns :running while tasks remain", %{scheduler: pid} do
      {:ok, _} = Scheduler.request_task(pid, "agent-1")
      {:ok, :running} = Scheduler.report_result(pid, "@repo/ui#build", :success)
    end

    test "returns :complete when last task succeeds", %{scheduler: pid} do
      {:ok, _} = Scheduler.request_task(pid, "agent-1")
      {:ok, :running} = Scheduler.report_result(pid, "@repo/ui#build", :success)

      {:ok, _} = Scheduler.request_task(pid, "agent-1")
      {:ok, _} = Scheduler.request_task(pid, "agent-2")
      {:ok, :running} = Scheduler.report_result(pid, "admin#build", :success)
      {:ok, :running} = Scheduler.report_result(pid, "api#build", :success)

      {:ok, _} = Scheduler.request_task(pid, "agent-1")
      {:ok, :complete} = Scheduler.report_result(pid, "admin#test", :success)
    end

    test "returns :failed when failure propagates to all remaining tasks", %{scheduler: pid} do
      {:ok, _} = Scheduler.request_task(pid, "agent-1")
      {:ok, :failed} = Scheduler.report_result(pid, "@repo/ui#build", :failed)
    end
  end

  describe "cache-hit optimization" do
    test "pre-marks cache hits as done and expands frontier" do
      json = File.read!(Path.join(@fixtures_dir, "dry_run_with_cache_hits.json"))
      {:ok, graph} = TaskGraph.parse(json)

      {:ok, pid} =
        Scheduler.start_link(
          graph: graph,
          run_id: "test-run-2",
          session_id: unique_session_id(),
          plugin: DxCore.Core.Scheduler.NullPlugin
        )

      {:ok, task} = Scheduler.request_task(pid, "agent-1")
      assert task.task_id in ["admin#build", "api#build"]
    end
  end

  describe "whereis/2" do
    test "returns the pid of a running scheduler", %{scheduler: pid, session_id: session_id} do
      assert Scheduler.whereis(session_id, "test-run-1") == pid
    end

    test "returns nil for a non-existent scheduler" do
      assert Scheduler.whereis("no-such-session", "no-such-run") == nil
    end
  end

  describe "shard propagation" do
    test "shard metadata flows through task assignment" do
      json = File.read!(Path.join(@fixtures_dir, "dry_run_sharded.json"))
      {:ok, graph} = TaskGraph.parse(json)

      {:ok, pid} =
        Scheduler.start_link(
          graph: graph,
          run_id: "shard-flow",
          session_id: unique_session_id(),
          plugin: DxCore.Core.Scheduler.NullPlugin
        )

      # First task is shared#build (no shard, only frontier task)
      {:ok, _} = Scheduler.request_task(pid, "a1")
      {:ok, :running} = Scheduler.report_result(pid, "shared#build", :success)

      # After completing shared#build, both sharded tasks are in the frontier
      {:ok, task} = Scheduler.request_task(pid, "a1")
      assert task.shard == %{index: 1, count: 2}

      {:ok, task2} = Scheduler.request_task(pid, "a2")
      assert task2.shard == %{index: 2, count: 2}
    end

    test "TaskState propagates shard from TaskGraph.Task" do
      # Create a graph with a shard field manually
      tasks = %{
        "pkg#build:0/2" => %TaskGraph.Task{
          task_id: "pkg#build:0/2",
          task: "build",
          package: "pkg",
          hash: "abc",
          command: "make",
          deps: [],
          dependents: [],
          cache_status: :miss,
          shard: %{index: 0, count: 2}
        }
      }

      graph = %TaskGraph{tasks: tasks}

      {:ok, pid} =
        Scheduler.start_link(
          graph: graph,
          run_id: "shard-run",
          session_id: unique_session_id(),
          plugin: DxCore.Core.Scheduler.NullPlugin
        )

      {:ok, task} = Scheduler.request_task(pid, "agent-1")
      assert task.shard == %{index: 0, count: 2}
    end
  end

  describe "on_task_complete plugin callback" do
    test "calls plugin.on_task_complete on success with duration and agent_info", %{graph: graph} do
      agent_info = %AgentInfo{agent_id: "a1", cpu_cores: 8, memory_mb: 16384}

      {:ok, pid} =
        Scheduler.start_link(
          graph: graph,
          run_id: "complete-test",
          session_id: unique_session_id(),
          plugin: RecordingPlugin,
          context: %{test_pid: self()}
        )

      {:ok, _task} = Scheduler.request_task(pid, "agent-1", agent_info)
      {:ok, :running} = Scheduler.report_result(pid, "@repo/ui#build", :success)

      assert_receive {:on_task_complete, "@repo/ui#build", :success, duration_ms, received_agent}
      assert is_integer(duration_ms)
      assert duration_ms >= 0
      assert received_agent.agent_id == "a1"
      assert received_agent.cpu_cores == 8
    end

    test "calls plugin.on_task_complete on failure", %{graph: graph} do
      agent_info = %AgentInfo{agent_id: "a2", cpu_cores: 4, memory_mb: 8192}

      {:ok, pid} =
        Scheduler.start_link(
          graph: graph,
          run_id: "fail-test",
          session_id: unique_session_id(),
          plugin: RecordingPlugin,
          context: %{test_pid: self()}
        )

      {:ok, _task} = Scheduler.request_task(pid, "agent-1", agent_info)
      {:ok, :failed} = Scheduler.report_result(pid, "@repo/ui#build", :failed)

      assert_receive {:on_task_complete, "@repo/ui#build", :failed, duration_ms, received_agent}
      assert is_integer(duration_ms)
      assert received_agent.agent_id == "a2"
    end

    test "scheduler survives plugin on_task_complete crash", %{graph: graph} do
      {:ok, pid} =
        Scheduler.start_link(
          graph: graph,
          run_id: "crash-test",
          session_id: unique_session_id(),
          plugin: CrashingPlugin
        )

      {:ok, _task} = Scheduler.request_task(pid, "agent-1")
      # Should not crash the scheduler
      {:ok, :running} = Scheduler.report_result(pid, "@repo/ui#build", :success)

      # Scheduler should still be alive and functional
      assert Process.alive?(pid)
      {:ok, _task} = Scheduler.request_task(pid, "agent-2")
    end

    test "passes context to plugin callbacks", %{graph: graph} do
      context = %{tenant_id: "tenant-123", test_pid: self()}

      {:ok, pid} =
        Scheduler.start_link(
          graph: graph,
          run_id: "context-test",
          session_id: unique_session_id(),
          plugin: RecordingPlugin,
          context: context
        )

      {:ok, _task} = Scheduler.request_task(pid, "agent-1", %AgentInfo{agent_id: "a1"})
      {:ok, :running} = Scheduler.report_result(pid, "@repo/ui#build", :success)

      assert_receive {:on_task_complete, "@repo/ui#build", :success, _duration_ms, _agent}
    end
  end
end
