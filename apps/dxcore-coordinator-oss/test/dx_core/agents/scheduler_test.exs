defmodule DxCore.Agents.SchedulerTest do
  use ExUnit.Case, async: true

  alias DxCore.Agents.Scheduler
  alias DxCore.Agents.TaskGraph

  @fixtures_dir Path.join([__DIR__, "..", "..", "fixtures"])

  defp unique_session_id do
    "test-session-#{System.unique_integer([:positive])}"
  end

  setup do
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

    %{scheduler: pid, session_id: session_id}
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
end
