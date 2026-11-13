defmodule DxCore.Core.SchedulerTimelineTest do
  # #16021: a run's timeline needs each task's ready and start times. The
  # scheduler records them on the task it hands to the plugin.
  use ExUnit.Case, async: true

  alias DxCore.Core.Scheduler
  alias DxCore.Core.TaskGraph

  @fixtures_dir Path.join([__DIR__, "..", "..", "fixtures"])

  defmodule CapturePlugin do
    @moduledoc false
    defdelegate select_task(frontier, agent, context), to: DxCore.Core.Scheduler.NullPlugin
    defdelegate expand_graph(graph, context), to: DxCore.Core.Scheduler.NullPlugin

    def on_task_complete(task, _result, _duration_ms, _agent, %{test_pid: pid}) do
      send(pid, {:completed, task})
      :ok
    end
  end

  setup do
    registry = :"timeline_registry_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, keys: :unique, name: registry})
    {:ok, graph} = TaskGraph.parse(File.read!(Path.join(@fixtures_dir, "dry_run_simple.json")))

    {:ok, pid} =
      Scheduler.start_link(
        graph: graph,
        registry: registry,
        run_id: "run-#{System.unique_integer([:positive])}",
        session_id: "s",
        plugin: CapturePlugin,
        failure_strategy: :continue_all,
        context: %{test_pid: self()}
      )

    %{pid: pid}
  end

  test "a task carries its ready and start times; a dependent is ready only once its dependency is done",
       %{pid: pid} do
    before = DateTime.utc_now()
    {:ok, ui} = Scheduler.request_task(pid, "agent-1")
    assert ui.task_id == "@repo/ui#build"
    assert %DateTime{} = ui.ready_at
    assert %DateTime{} = ui.started_at
    # A root task is ready from the moment the scheduler starts, before this request.
    assert DateTime.compare(ui.ready_at, before) != :gt
    assert DateTime.compare(ui.ready_at, ui.started_at) != :gt

    Process.sleep(20)
    done_at = DateTime.utc_now()
    {:ok, :running} = Scheduler.report_result(pid, "@repo/ui#build", "agent-1", :success)

    assert_receive {:completed, %{task_id: "@repo/ui#build"} = completed}
    assert {completed.ready_at, completed.started_at} == {ui.ready_at, ui.started_at}

    {:ok, next} = Scheduler.request_task(pid, "agent-1")
    assert next.task_id in ["admin#build", "api#build"]
    assert %DateTime{} = next.ready_at
    assert DateTime.compare(next.ready_at, done_at) != :lt
  end

  test "a released task keeps its ready time and loses its start time", %{pid: pid} do
    {:ok, ui} = Scheduler.request_task(pid, "agent-1")
    :ok = Scheduler.release_agent(pid, "agent-1")

    task = Scheduler.status(pid).tasks["@repo/ui#build"]
    assert task.status == :pending
    assert task.ready_at == ui.ready_at
    assert task.started_at == nil
  end
end
