defmodule DxCore.Core.SchedulerDeadlineTest do
  # #15513: the coordinator owns a run with a deadline. The scheduler drains at
  # the deadline and asks, once, for the run to end when nothing runs, at the
  # hard stop, or when topology fails the run.
  use ExUnit.Case, async: true

  alias DxCore.Core.Scheduler
  alias DxCore.Core.TaskGraph

  @fixtures_dir Path.join([__DIR__, "..", "..", "fixtures"])

  defmodule StopSink do
    @moduledoc false
    def stopped(run_id, reason, context, test_pid),
      do: send(test_pid, {:run_stopped, run_id, reason, Map.has_key?(context, :on_run_stopped)})

    def raise_stopped(_run_id, _reason, _context, test_pid) do
      send(test_pid, :hook_ran)
      raise "hook down"
    end
  end

  defmodule Forward do
    @moduledoc false
    def handle(event, _measurements, meta, test_pid),
      do: send(test_pid, {:telemetry, event, meta})
  end

  # No agent can run anything: topology evaluation fails every frontier task.
  defmodule UnassignablePlugin do
    @moduledoc false
    defdelegate select_task(frontier, agent, context), to: DxCore.Core.Scheduler.NullPlugin
    defdelegate expand_graph(graph, context), to: DxCore.Core.Scheduler.NullPlugin

    defdelegate on_task_complete(task, result, duration_ms, agent, context),
      to: DxCore.Core.Scheduler.NullPlugin

    def evaluate_assignability(frontier_tasks, _agents), do: {[], frontier_tasks}
  end

  setup do
    # Its own registry: the shared one is started by other async test modules.
    registry = :"deadline_registry_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, keys: :unique, name: registry})
    Process.put(:deadline_registry, registry)
    {:ok, graph} = TaskGraph.parse(File.read!(Path.join(@fixtures_dir, "dry_run_simple.json")))
    %{graph: graph}
  end

  defp start(graph, opts) do
    run_id = "run-#{System.unique_integer([:positive])}"

    base = [
      graph: graph,
      registry: Process.get(:deadline_registry),
      run_id: run_id,
      session_id: "s-#{run_id}",
      plugin: DxCore.Core.Scheduler.NullPlugin,
      failure_strategy: :continue_all,
      context: %{on_run_stopped: {StopSink, :stopped, [self()]}}
    ]

    {:ok, pid} = Scheduler.start_link(Keyword.merge(base, opts))
    {pid, run_id}
  end

  defp in_ms(ms), do: DateTime.add(DateTime.utc_now(), ms, :millisecond)

  test "at the deadline a running task keeps running and no new task goes out", %{graph: graph} do
    id = "deadline-first-#{System.unique_integer([:positive])}"
    :telemetry.attach(id, [:dxcore, :scheduler, :deadline], &Forward.handle/4, self())
    on_exit(fn -> :telemetry.detach(id) end)

    {pid, run_id} = start(graph, deadline_at: in_ms(100), hard_stop_at: in_ms(5_000))
    {:ok, task} = Scheduler.request_task(pid, "agent-1")

    assert_receive {:telemetry, [:dxcore, :scheduler, :deadline],
                    %{run_id: ^run_id, kind: :drain}},
                   1_000

    assert Scheduler.request_task(pid, "agent-2") == :no_task
    refute_received {:run_stopped, ^run_id, _, _}

    # The running task ends: nothing runs, tasks are left, so it asks to stop.
    {:ok, :running} = Scheduler.report_result(pid, task.task_id, "agent-1", :success)
    assert_receive {:run_stopped, ^run_id, :drained, true}, 1_000
    refute_receive {:run_stopped, ^run_id, _, _}, 300
  end

  test "an idle run stops once at the deadline", %{graph: graph} do
    {_pid, run_id} = start(graph, deadline_at: in_ms(50), hard_stop_at: in_ms(1_000))
    assert_receive {:run_stopped, ^run_id, :drained, true}, 1_000
    # The hard stop (at 1_000 ms) does not ask again.
    refute_receive {:run_stopped, ^run_id, _, _}, 1_200
  end

  test "at the hard stop a still-running run is stopped", %{graph: graph} do
    {pid, run_id} = start(graph, deadline_at: in_ms(50), hard_stop_at: in_ms(250))
    {:ok, _task} = Scheduler.request_task(pid, "agent-1")
    refute_receive {:run_stopped, ^run_id, _, _}, 150
    assert_receive {:run_stopped, ^run_id, :hard_stop, true}, 1_000
  end

  test "a finished run is never stopped", %{graph: graph} do
    {pid, run_id} = start(graph, deadline_at: in_ms(400), hard_stop_at: in_ms(500))

    for _ <- 1..4 do
      {:ok, t} = Scheduler.request_task(pid, "agent-1")
      {:ok, _} = Scheduler.report_result(pid, t.task_id, "agent-1", :success)
    end

    refute_receive {:run_stopped, ^run_id, _, _}, 800
  end

  test "a run without a deadline never calls the hook, even drained", %{graph: graph} do
    {pid, run_id} = start(graph, [])
    {:ok, 0} = Scheduler.drain(pid)
    refute_receive {:run_stopped, ^run_id, _, _}, 300
  end

  test "a deadline already past drains at once", %{graph: graph} do
    past = DateTime.add(DateTime.utc_now(), -1, :second)
    {pid, run_id} = start(graph, deadline_at: past, hard_stop_at: in_ms(5_000))
    assert_receive {:run_stopped, ^run_id, :drained, true}, 1_000
    assert Scheduler.request_task(pid, "agent-1") == :no_task
  end

  @tag capture_log: true
  test "a raising hook does not take the scheduler down", %{graph: graph} do
    {pid, _run_id} =
      start(graph,
        deadline_at: in_ms(50),
        hard_stop_at: in_ms(5_000),
        context: %{on_run_stopped: {StopSink, :raise_stopped, [self()]}}
      )

    assert_receive :hook_ran, 1_000
    assert %{} = Scheduler.status(pid)
    assert Process.alive?(pid)
    assert %{} = Scheduler.status(pid)
  end

  test "the drain and the hard stop are told to telemetry", %{graph: graph} do
    id = "deadline-#{System.unique_integer([:positive])}"
    me = self()

    :telemetry.attach_many(
      id,
      [[:dxcore, :scheduler, :deadline], [:dxcore, :scheduler, :run_stop_requested]],
      &Forward.handle/4,
      me
    )

    on_exit(fn -> :telemetry.detach(id) end)
    {_pid, run_id} = start(graph, deadline_at: in_ms(50), hard_stop_at: in_ms(5_000))

    assert_receive {:telemetry, [:dxcore, :scheduler, :deadline],
                    %{run_id: ^run_id, kind: :drain}},
                   1_000

    assert_receive {:telemetry, [:dxcore, :scheduler, :run_stop_requested],
                    %{run_id: ^run_id, reason: :drained}},
                   1_000
  end

  test "deadlines go together and in order", %{graph: graph} do
    assert_raise ArgumentError, ~r/together/, fn -> start(graph, deadline_at: in_ms(100)) end
    assert_raise ArgumentError, ~r/together/, fn -> start(graph, hard_stop_at: in_ms(100)) end

    assert_raise ArgumentError, ~r/before/, fn ->
      start(graph, deadline_at: in_ms(1_000), hard_stop_at: in_ms(100))
    end
  end

  @tag capture_log: true
  test "a topology failure stops a managed run", %{graph: graph} do
    {pid, run_id} =
      start(graph,
        plugin: UnassignablePlugin,
        failure_strategy: :fail_fast,
        deadline_at: in_ms(60_000),
        hard_stop_at: in_ms(61_000),
        context: %{
          on_run_stopped: {StopSink, :stopped, [self()]},
          topology_check: "explicit",
          topology: %{"agents" => 0},
          agent_lister: fn _ -> [] end
        }
      )

    Scheduler.check_topology(pid)
    assert_receive {:run_stopped, ^run_id, :failed, true}, 3_000
  end
end
