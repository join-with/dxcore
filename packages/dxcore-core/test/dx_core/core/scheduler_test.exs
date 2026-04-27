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
        plugin: DxCore.Core.Scheduler.NullPlugin,
        failure_strategy: :continue_all
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

  describe "report_result/4" do
    test "completing a task unblocks dependents", %{scheduler: pid} do
      {:ok, task} = Scheduler.request_task(pid, "agent-1")
      assert task.task_id == "@repo/ui#build"

      {:ok, _} = Scheduler.report_result(pid, "@repo/ui#build", "agent-1", :success)

      {:ok, task2} = Scheduler.request_task(pid, "agent-1")
      assert task2.task_id in ["admin#build", "api#build"]

      {:ok, task3} = Scheduler.request_task(pid, "agent-2")
      assert task3.task_id in ["admin#build", "api#build"]
      assert task2.task_id != task3.task_id
    end

    test "failing a task propagates failure to dependents", %{scheduler: pid} do
      {:ok, _} = Scheduler.request_task(pid, "agent-1")
      {:ok, _} = Scheduler.report_result(pid, "@repo/ui#build", "agent-1", :failed)

      status = Scheduler.status(pid)
      assert status.tasks["admin#build"].status == :skipped
      assert status.tasks["api#build"].status == :skipped
      assert status.tasks["admin#test"].status == :skipped
    end
  end

  describe "report_result strict ACK rule" do
    test "accepts when assigned_to matches agent_id and status is running", %{scheduler: pid} do
      {:ok, _} = Scheduler.request_task(pid, "agent-1")
      assert {:ok, _} = Scheduler.report_result(pid, "@repo/ui#build", "agent-1", :success)
    end

    test "rejects when reporting agent != assigned agent", %{scheduler: pid} do
      {:ok, _} = Scheduler.request_task(pid, "agent-1")

      assert {:error, :not_assigned} =
               Scheduler.report_result(pid, "@repo/ui#build", "agent-2", :success)
    end

    test "rejects when task is :pending with no assignment", %{scheduler: pid} do
      # Don't request first
      assert {:error, :not_assigned} =
               Scheduler.report_result(pid, "@repo/ui#build", "agent-1", :success)
    end

    test "rejects when task is already :done", %{scheduler: pid} do
      {:ok, _} = Scheduler.request_task(pid, "agent-1")
      {:ok, _} = Scheduler.report_result(pid, "@repo/ui#build", "agent-1", :success)

      assert {:error, :not_assigned} =
               Scheduler.report_result(pid, "@repo/ui#build", "agent-1", :success)
    end

    test "rejects unknown task_id", %{scheduler: pid} do
      assert {:error, :unknown_task} =
               Scheduler.report_result(pid, "nonexistent", "agent-1", :success)
    end
  end

  describe "telemetry events" do
    test "report_result emits :ack_rejected on wrong agent", %{scheduler: pid} do
      test_pid = self()
      handler_id = "ack-rejected-test-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:dxcore, :scheduler, :ack_rejected],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:ack_rejected, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      {:ok, _} = Scheduler.request_task(pid, "agent-1")

      assert {:error, :not_assigned} =
               Scheduler.report_result(pid, "@repo/ui#build", "wrong-agent", :success)

      assert_receive {:ack_rejected, %{count: 1},
                      %{
                        agent_id: "wrong-agent",
                        task_id: "@repo/ui#build",
                        reason: :wrong_agent_or_status
                      }},
                     500
    end

    test "report_result emits :ack_rejected on unknown task", %{scheduler: pid} do
      test_pid = self()
      handler_id = "unknown-task-test-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:dxcore, :scheduler, :ack_rejected],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:ack_rejected, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:error, :unknown_task} =
               Scheduler.report_result(pid, "nonexistent", "agent-1", :success)

      assert_receive {:ack_rejected, %{count: 1},
                      %{agent_id: "agent-1", task_id: "nonexistent", reason: :unknown_task}},
                     500
    end
  end

  describe "report_result returns run_status atomically" do
    test "returns :running while tasks remain", %{scheduler: pid} do
      {:ok, _} = Scheduler.request_task(pid, "agent-1")
      {:ok, :running} = Scheduler.report_result(pid, "@repo/ui#build", "agent-1", :success)
    end

    test "returns :complete when last task succeeds", %{scheduler: pid} do
      {:ok, _} = Scheduler.request_task(pid, "agent-1")
      {:ok, :running} = Scheduler.report_result(pid, "@repo/ui#build", "agent-1", :success)

      {:ok, t2} = Scheduler.request_task(pid, "agent-1")
      {:ok, t3} = Scheduler.request_task(pid, "agent-2")
      {:ok, :running} = Scheduler.report_result(pid, t2.task_id, "agent-1", :success)
      {:ok, :running} = Scheduler.report_result(pid, t3.task_id, "agent-2", :success)

      {:ok, _} = Scheduler.request_task(pid, "agent-1")
      {:ok, :complete} = Scheduler.report_result(pid, "admin#test", "agent-1", :success)
    end

    test "returns :failed when failure propagates to all remaining tasks", %{scheduler: pid} do
      {:ok, _} = Scheduler.request_task(pid, "agent-1")
      {:ok, :failed} = Scheduler.report_result(pid, "@repo/ui#build", "agent-1", :failed)
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

  describe "whereis/3" do
    test "returns the pid of a running scheduler", %{scheduler: pid, session_id: session_id} do
      assert Scheduler.whereis(nil, session_id, "test-run-1") == pid
    end

    test "returns nil for a non-existent scheduler" do
      assert Scheduler.whereis(nil, "no-such-session", "no-such-run") == nil
    end
  end

  describe "org-scoped registry keys" do
    test "schedulers in different orgs do not collide on same {session_id, run_id}" do
      json = File.read!(Path.join(@fixtures_dir, "dry_run_simple.json"))
      {:ok, graph} = TaskGraph.parse(json)

      shared_session = "shared-session-#{System.unique_integer([:positive])}"
      shared_run = "shared-run-#{System.unique_integer([:positive])}"

      {:ok, pid_a} =
        Scheduler.start_link(
          graph: graph,
          run_id: shared_run,
          session_id: shared_session,
          org_id: "org-1",
          plugin: DxCore.Core.Scheduler.NullPlugin
        )

      {:ok, pid_b} =
        Scheduler.start_link(
          graph: graph,
          run_id: shared_run,
          session_id: shared_session,
          org_id: "org-2",
          plugin: DxCore.Core.Scheduler.NullPlugin
        )

      assert pid_a != pid_b
      assert Scheduler.whereis("org-1", shared_session, shared_run) == pid_a
      assert Scheduler.whereis("org-2", shared_session, shared_run) == pid_b
      assert Scheduler.whereis(nil, shared_session, shared_run) == nil
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
      {:ok, :running} = Scheduler.report_result(pid, "shared#build", "a1", :success)

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
      {:ok, :running} = Scheduler.report_result(pid, "@repo/ui#build", "agent-1", :success)

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
      {:ok, :failed} = Scheduler.report_result(pid, "@repo/ui#build", "agent-1", :failed)

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
      {:ok, :running} = Scheduler.report_result(pid, "@repo/ui#build", "agent-1", :success)

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
      {:ok, :running} = Scheduler.report_result(pid, "@repo/ui#build", "agent-1", :success)

      assert_receive {:on_task_complete, "@repo/ui#build", :success, _duration_ms, _agent}
    end
  end

  describe "failure_strategy: :continue_all" do
    setup do
      json = File.read!(Path.join(@fixtures_dir, "dry_run_diamond.json"))
      {:ok, graph} = TaskGraph.parse(json)

      {:ok, pid} =
        Scheduler.start_link(
          graph: graph,
          run_id: "continue-all-run",
          session_id: unique_session_id(),
          plugin: DxCore.Core.Scheduler.NullPlugin,
          failure_strategy: :continue_all
        )

      %{scheduler: pid}
    end

    test "marks pending dependents as :skipped, not :failed", %{scheduler: pid} do
      {:ok, _} = Scheduler.request_task(pid, "agent-1")
      {:ok, _run_status} = Scheduler.report_result(pid, "pkg#lint", "agent-1", :failed)

      status = Scheduler.status(pid)
      assert status.tasks["pkg#lint"].status == :failed
      assert status.tasks["pkg#build"].status == :skipped
      assert status.tasks["pkg#test"].status == :skipped
      assert status.tasks["pkg#deploy"].status == :skipped
    end

    test "continues independent tasks when a branch fails", %{scheduler: pid} do
      {:ok, _} = Scheduler.request_task(pid, "agent-1")
      {:ok, :running} = Scheduler.report_result(pid, "pkg#lint", "agent-1", :success)

      {:ok, t1} = Scheduler.request_task(pid, "agent-1")
      {:ok, t2} = Scheduler.request_task(pid, "agent-2")

      build_agent = if t1.task_id == "pkg#build", do: "agent-1", else: "agent-2"
      _test_agent = if t2.task_id == "pkg#test", do: "agent-2", else: "agent-1"

      {:ok, :running} = Scheduler.report_result(pid, "pkg#build", build_agent, :failed)

      status = Scheduler.status(pid)
      assert status.tasks["pkg#build"].status == :failed
      assert status.tasks["pkg#test"].status == :running
      assert status.tasks["pkg#deploy"].status == :skipped
    end

    test "run resolves to :failed after all independent tasks complete", %{scheduler: pid} do
      {:ok, _} = Scheduler.request_task(pid, "agent-1")
      {:ok, :running} = Scheduler.report_result(pid, "pkg#lint", "agent-1", :success)

      {:ok, t1} = Scheduler.request_task(pid, "agent-1")
      {:ok, t2} = Scheduler.request_task(pid, "agent-2")

      build_agent = if t1.task_id == "pkg#build", do: "agent-1", else: "agent-2"
      test_agent = if t2.task_id == "pkg#test", do: "agent-2", else: "agent-1"

      # Fail build, test still running
      {:ok, :running} = Scheduler.report_result(pid, "pkg#build", build_agent, :failed)

      # Complete test — deploy is skipped (depends on failed build), run is failed
      {:ok, :failed} = Scheduler.report_result(pid, "pkg#test", test_agent, :success)
    end

    test "only skips :pending dependents, not :running ones", %{scheduler: pid} do
      {:ok, _} = Scheduler.request_task(pid, "agent-1")
      {:ok, :running} = Scheduler.report_result(pid, "pkg#lint", "agent-1", :success)

      {:ok, t1} = Scheduler.request_task(pid, "agent-1")
      {:ok, _t2} = Scheduler.request_task(pid, "agent-2")

      build_agent = if t1.task_id == "pkg#build", do: "agent-1", else: "agent-2"

      {:ok, :running} = Scheduler.report_result(pid, "pkg#build", build_agent, :failed)

      status = Scheduler.status(pid)
      assert status.tasks["pkg#test"].status == :running
    end
  end

  describe "failure_strategy: :fail_fast" do
    setup do
      json = File.read!(Path.join(@fixtures_dir, "dry_run_diamond.json"))
      {:ok, graph} = TaskGraph.parse(json)

      {:ok, pid} =
        Scheduler.start_link(
          graph: graph,
          run_id: "fail-fast-run",
          session_id: unique_session_id(),
          plugin: DxCore.Core.Scheduler.NullPlugin,
          failure_strategy: :fail_fast
        )

      %{scheduler: pid}
    end

    test "skips all pending tasks on first failure", %{scheduler: pid} do
      {:ok, _} = Scheduler.request_task(pid, "agent-1")
      {:ok, :failed} = Scheduler.report_result(pid, "pkg#lint", "agent-1", :failed)

      status = Scheduler.status(pid)
      assert status.tasks["pkg#lint"].status == :failed
      assert status.tasks["pkg#build"].status == :skipped
      assert status.tasks["pkg#test"].status == :skipped
      assert status.tasks["pkg#deploy"].status == :skipped
    end

    test "waits for running tasks to complete before declaring failed", %{scheduler: pid} do
      {:ok, _} = Scheduler.request_task(pid, "agent-1")
      {:ok, :running} = Scheduler.report_result(pid, "pkg#lint", "agent-1", :success)

      {:ok, t1} = Scheduler.request_task(pid, "agent-1")
      {:ok, t2} = Scheduler.request_task(pid, "agent-2")

      build_agent = if t1.task_id == "pkg#build", do: "agent-1", else: "agent-2"
      test_agent = if t2.task_id == "pkg#test", do: "agent-2", else: "agent-1"

      {:ok, :running} = Scheduler.report_result(pid, "pkg#build", build_agent, :failed)

      status = Scheduler.status(pid)
      assert status.tasks["pkg#test"].status == :running
      assert status.tasks["pkg#deploy"].status == :skipped

      assert :no_task = Scheduler.request_task(pid, "agent-1")

      {:ok, :failed} = Scheduler.report_result(pid, "pkg#test", test_agent, :success)
    end

    test "does not assign new tasks after fail_fast triggered", %{scheduler: pid} do
      {:ok, _} = Scheduler.request_task(pid, "agent-1")
      {:ok, :failed} = Scheduler.report_result(pid, "pkg#lint", "agent-1", :failed)

      assert :no_task = Scheduler.request_task(pid, "agent-1")
    end
  end

  describe "report_result with exit_code" do
    test "stores exit_code on TaskState when tuple result provided", %{scheduler: pid} do
      {:ok, _} = Scheduler.request_task(pid, "agent-1")
      {:ok, :running} = Scheduler.report_result(pid, "@repo/ui#build", "agent-1", {:success, 0})

      status = Scheduler.status(pid)
      assert status.tasks["@repo/ui#build"].exit_code == 0
    end

    test "stores exit_code on failed result", %{scheduler: pid} do
      {:ok, _} = Scheduler.request_task(pid, "agent-1")
      {:ok, _} = Scheduler.report_result(pid, "@repo/ui#build", "agent-1", {:failed, 1})

      status = Scheduler.status(pid)
      assert status.tasks["@repo/ui#build"].exit_code == 1
    end

    test "bare :success/:failed atoms still work (backward compat)", %{scheduler: pid} do
      {:ok, _} = Scheduler.request_task(pid, "agent-1")
      {:ok, :running} = Scheduler.report_result(pid, "@repo/ui#build", "agent-1", :success)

      status = Scheduler.status(pid)
      assert status.tasks["@repo/ui#build"].exit_code == nil
    end
  end

  describe "duration_ms and cache_status on TaskState" do
    test "duration_ms is computed and stored on report_result", %{scheduler: pid} do
      {:ok, _} = Scheduler.request_task(pid, "agent-1")
      Process.sleep(5)
      {:ok, _} = Scheduler.report_result(pid, "@repo/ui#build", "agent-1", :success)

      status = Scheduler.status(pid)
      assert status.tasks["@repo/ui#build"].duration_ms >= 5
    end

    test "cache_status is preserved from graph" do
      json = File.read!(Path.join(@fixtures_dir, "dry_run_with_cache_hits.json"))
      {:ok, graph} = TaskGraph.parse(json)

      {:ok, pid} =
        Scheduler.start_link(
          graph: graph,
          run_id: "cache-status-run",
          session_id: unique_session_id(),
          plugin: DxCore.Core.Scheduler.NullPlugin
        )

      status = Scheduler.status(pid)
      assert Enum.any?(status.tasks, fn {_id, t} -> t.cache_status == :hit end)
      assert Enum.any?(status.tasks, fn {_id, t} -> t.cache_status == :miss end)
    end
  end

  describe "requirements propagation" do
    test "TaskState carries requirements from TaskGraph.Task" do
      json =
        Jason.encode!(%{
          "tasks" => [
            %{
              "taskId" => "cli#build",
              "task" => "build",
              "package" => "cli",
              "hash" => "abc",
              "command" => "mix compile",
              "dependencies" => [],
              "dependents" => [],
              "cache" => %{"status" => "MISS"},
              "requirements" => %{"zig" => "true"}
            }
          ]
        })

      {:ok, graph} = TaskGraph.parse(json)
      session_id = unique_session_id()

      {:ok, pid} =
        Scheduler.start_link(
          graph: graph,
          run_id: "run-req",
          session_id: session_id,
          plugin: RecordingPlugin,
          context: %{}
        )

      {:ok, task_state} = Scheduler.request_task(pid, "agent-1")
      assert task_state.requirements == %{"zig" => "true"}
    end

    test "TaskState defaults requirements to empty map" do
      json = File.read!(Path.join(@fixtures_dir, "dry_run_simple.json"))
      {:ok, graph} = TaskGraph.parse(json)
      session_id = unique_session_id()

      {:ok, pid} =
        Scheduler.start_link(
          graph: graph,
          run_id: "run-no-req",
          session_id: session_id,
          plugin: RecordingPlugin,
          context: %{}
        )

      {:ok, task_state} = Scheduler.request_task(pid, "agent-1")
      assert task_state.requirements == %{}
    end
  end

  describe "completed_by" do
    test "preserves agent_id after task completion", %{scheduler: pid} do
      {:ok, _} = Scheduler.request_task(pid, "agent-1")
      {:ok, :running} = Scheduler.report_result(pid, "@repo/ui#build", "agent-1", :success)

      status = Scheduler.status(pid)
      assert status.tasks["@repo/ui#build"].assigned_to == nil
      assert status.tasks["@repo/ui#build"].completed_by == "agent-1"
    end
  end

  describe "rehydration" do
    defp build_graph_for_rehydration do
      # Three tasks: a → b, a → c
      %TaskGraph{
        tasks: %{
          "a" => %TaskGraph.Task{
            task_id: "a",
            task: "test",
            package: "pkg",
            hash: "h",
            command: "true",
            deps: [],
            dependents: ["b", "c"],
            cache_status: :miss,
            cacheable: true,
            shard: nil
          },
          "b" => %TaskGraph.Task{
            task_id: "b",
            task: "test",
            package: "pkg",
            hash: "h",
            command: "true",
            deps: ["a"],
            dependents: [],
            cache_status: :miss,
            cacheable: true,
            shard: nil
          },
          "c" => %TaskGraph.Task{
            task_id: "c",
            task: "test",
            package: "pkg",
            hash: "h",
            command: "true",
            deps: ["a"],
            dependents: [],
            cache_status: :miss,
            cacheable: true,
            shard: nil
          }
        }
      }
    end

    test "init with rehydrate_from reconstructs state equivalent to a normal init that processed the same results" do
      graph = build_graph_for_rehydration()

      # Normal scheduler: process result for "a"
      {:ok, normal_pid} =
        Scheduler.start_link(
          graph: graph,
          run_id: "r1",
          session_id: "rehydrate-sess",
          plugin: DxCore.Core.Scheduler.NullPlugin
        )

      {:ok, _} = Scheduler.request_task(normal_pid, "agent-1")
      {:ok, _} = Scheduler.report_result(normal_pid, "a", "agent-1", :success)

      # Rehydrated scheduler: pass the same result via rehydrate_from
      results = [
        %{task_id: "a", status: :done, agent_id: "agent-1", duration_ms: 5}
      ]

      {:ok, rehydrated_pid} =
        Scheduler.start_link(
          graph: graph,
          run_id: "r2",
          session_id: "rehydrate-sess",
          plugin: DxCore.Core.Scheduler.NullPlugin,
          skip_expand?: true,
          rehydrate_from: results
        )

      norm = Scheduler.status(normal_pid)
      rehy = Scheduler.status(rehydrated_pid)

      assert norm.tasks["a"].status == :done
      assert rehy.tasks["a"].status == :done
      assert norm.tasks["a"].status == rehy.tasks["a"].status
      assert MapSet.equal?(norm.frontier, rehy.frontier)

      # Rehydration must populate completed_by and duration_ms from the result map,
      # regardless of how the normal scheduler computed them.
      assert rehy.tasks["a"].completed_by == "agent-1"
      assert rehy.tasks["a"].duration_ms == 5
    end

    test "rehydrate_from skips task_ids no longer in the graph" do
      graph = build_graph_for_rehydration()

      # Result references task "z" which is NOT in graph (e.g. cache flip)
      results = [%{task_id: "z", status: :done, agent_id: "agent-1", duration_ms: 5}]

      {:ok, pid} =
        Scheduler.start_link(
          graph: graph,
          run_id: "r3",
          session_id: "rehydrate-sess-2",
          plugin: DxCore.Core.Scheduler.NullPlugin,
          skip_expand?: true,
          rehydrate_from: results
        )

      status = Scheduler.status(pid)
      refute Map.has_key?(status.tasks, "z")
      # All tasks remain in their initial states (a frontier, b/c blocked)
      assert status.tasks["a"].status == :pending
    end

    test "rehydrate_from with a failed task propagates skipped status to dependents" do
      graph = build_graph_for_rehydration()

      results = [%{task_id: "a", status: :failed, agent_id: "agent-1", duration_ms: 5}]

      {:ok, pid} =
        Scheduler.start_link(
          graph: graph,
          run_id: "r4",
          session_id: "rehydrate-sess-3",
          plugin: DxCore.Core.Scheduler.NullPlugin,
          failure_strategy: :continue_all,
          skip_expand?: true,
          rehydrate_from: results
        )

      status = Scheduler.status(pid)
      assert status.tasks["a"].status == :failed
      assert status.tasks["b"].status == :skipped
      assert status.tasks["c"].status == :skipped
    end

    test "rehydrate_from with a failed task seeds failed_fast under :fail_fast strategy" do
      graph = build_graph_for_rehydration()

      results = [%{task_id: "a", status: :failed, agent_id: "agent-1", duration_ms: 5}]

      {:ok, pid} =
        Scheduler.start_link(
          graph: graph,
          run_id: "r5",
          session_id: "rehydrate-sess-4",
          plugin: DxCore.Core.Scheduler.NullPlugin,
          failure_strategy: :fail_fast,
          skip_expand?: true,
          rehydrate_from: results
        )

      status = Scheduler.status(pid)
      assert status.tasks["a"].status == :failed
      assert status.run_status == :failed
    end

    test ":fail_fast rehydration skips independent pending tasks (C1)" do
      # Graph: a → b/c, plus independent leaf d.
      # Under :fail_fast, a failure must skip *every* pending task — not just
      # transitive dependents — to mirror the live failure path.
      graph = %TaskGraph{
        tasks:
          Map.put(build_graph_for_rehydration().tasks, "d", %TaskGraph.Task{
            task_id: "d",
            task: "test",
            package: "pkg",
            hash: "h",
            command: "true",
            deps: [],
            dependents: [],
            cache_status: :miss,
            cacheable: true,
            shard: nil
          })
      }

      results = [%{task_id: "a", status: :failed, agent_id: "agent-1", duration_ms: 5}]

      {:ok, pid} =
        Scheduler.start_link(
          graph: graph,
          run_id: "r-c1",
          session_id: "rehydrate-sess-c1",
          plugin: DxCore.Core.Scheduler.NullPlugin,
          failure_strategy: :fail_fast,
          skip_expand?: true,
          rehydrate_from: results
        )

      status = Scheduler.status(pid)
      assert status.tasks["a"].status == :failed
      assert status.tasks["b"].status == :skipped
      assert status.tasks["c"].status == :skipped
      # The original bug: independent task `d` stayed :pending under fail_fast.
      assert status.tasks["d"].status == :skipped
      assert status.run_status == :failed
    end
  end

  describe "summary/1" do
    test "returns structured summary after successful run", %{scheduler: pid} do
      {:ok, _} = Scheduler.request_task(pid, "agent-1")
      {:ok, :running} = Scheduler.report_result(pid, "@repo/ui#build", "agent-1", {:success, 0})

      {:ok, t2} = Scheduler.request_task(pid, "agent-1")
      {:ok, t3} = Scheduler.request_task(pid, "agent-2")

      admin_agent = if t2.task_id == "admin#build", do: "agent-1", else: "agent-2"
      api_agent = if t2.task_id == "api#build", do: "agent-1", else: "agent-2"

      {:ok, :running} = Scheduler.report_result(pid, "admin#build", admin_agent, {:success, 0})
      {:ok, :running} = Scheduler.report_result(pid, "api#build", api_agent, {:success, 0})

      _ = t3

      {:ok, _} = Scheduler.request_task(pid, "agent-1")
      {:ok, :complete} = Scheduler.report_result(pid, "admin#test", "agent-1", {:success, 0})

      summary = Scheduler.summary(pid)
      assert summary.status == :complete
      assert summary.counts.passed == 4
      assert summary.counts.failed == 0
      assert summary.counts.skipped == 0
      assert summary.counts.cached == 0
      assert summary.failures == []
      assert length(summary.tasks) == 4
    end

    test "includes failed and skipped tasks in summary" do
      json = File.read!(Path.join(@fixtures_dir, "dry_run_diamond.json"))
      {:ok, graph} = TaskGraph.parse(json)

      {:ok, pid} =
        Scheduler.start_link(
          graph: graph,
          run_id: "summary-fail-run",
          session_id: unique_session_id(),
          plugin: DxCore.Core.Scheduler.NullPlugin,
          failure_strategy: :continue_all
        )

      {:ok, _} = Scheduler.request_task(pid, "agent-1")
      {:ok, :failed} = Scheduler.report_result(pid, "pkg#lint", "agent-1", {:failed, 1})

      summary = Scheduler.summary(pid)
      assert summary.status == :failed
      assert summary.counts.passed == 0
      assert summary.counts.failed == 1
      assert summary.counts.skipped == 3
      assert length(summary.failures) == 1
      assert hd(summary.failures).task_id == "pkg#lint"
      assert hd(summary.failures).exit_code == 1
    end

    test "cached tasks counted separately" do
      json = File.read!(Path.join(@fixtures_dir, "dry_run_with_cache_hits.json"))
      {:ok, graph} = TaskGraph.parse(json)

      {:ok, pid} =
        Scheduler.start_link(
          graph: graph,
          run_id: "summary-cache-run",
          session_id: unique_session_id(),
          plugin: DxCore.Core.Scheduler.NullPlugin
        )

      summary = Scheduler.summary(pid)
      assert summary.counts.cached > 0
    end
  end
end
