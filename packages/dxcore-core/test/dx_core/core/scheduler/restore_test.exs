defmodule DxCore.Core.Scheduler.RestoreTest do
  @moduledoc """
  A scheduler restarted from the options it was first started with (what
  Horde does when it moves one to another node) keeps the run's progress
  through its `:state_loader` (#11951).
  """

  # Not async: it starts the globally named scheduler registry, which the
  # async SchedulerTest starts too.
  use ExUnit.Case, async: false

  alias DxCore.Core.AgentInfo
  alias DxCore.Core.Scheduler
  alias DxCore.Core.TaskGraph

  defmodule Loader do
    @moduledoc false
    def load(_run_id, state), do: {:ok, state}
    def bad_shape(_run_id), do: {:ok, %{results: :nope}}
    def raises(_run_id), do: raise(__MODULE__.NeverNamedError)

    # Fails the first `failures` calls (a database that is briefly away),
    # then returns `state`. `counter` is an :atomics ref counting calls.
    def flaky(_run_id, counter, failures, state) do
      if :atomics.add_get(counter, 1, 1) <= failures,
        do: raise(__MODULE__.NeverNamedError, "connection not available"),
        else: {:ok, state}
    end

    defmodule NeverNamedError do
      defexception message: "loader blew up"
    end
  end

  defmodule AssignRecordingPlugin do
    @moduledoc false
    @behaviour DxCore.Core.SchedulerPlugin

    @impl true
    def select_task([], _agent, _context), do: nil
    def select_task(frontier, _agent, _context), do: Enum.min_by(frontier, & &1.task_id)

    @impl true
    def expand_graph(graph, _context), do: graph

    @impl true
    def on_task_complete(_task, _result, _duration_ms, _agent, _context), do: :ok

    @impl true
    def on_task_assigned(task, agent, context) do
      send(context.test_pid, {:assigned, task.task_id, task.assigned_to, agent.agent_id})
      :ok
    end

    @impl true
    def on_task_released(task, context) do
      send(context.test_pid, {:released, task.task_id, task.assigned_to})
      :ok
    end
  end

  defmodule Endpoint do
    @moduledoc false
    def broadcast(topic, event, payload) do
      send(:persistent_term.get({__MODULE__, topic}), {:broadcast, topic, event, payload})
      :ok
    end
  end

  setup do
    start_supervised!({Registry, keys: :unique, name: DxCore.Core.SchedulerRegistry})
    :ok
  end

  # a → b, a → c
  defp graph do
    task = fn id, deps, dependents ->
      %TaskGraph.Task{
        task_id: id,
        task: "test",
        package: "pkg",
        hash: "h",
        command: "true",
        deps: deps,
        dependents: dependents,
        cache_status: :miss,
        cacheable: true,
        shard: nil,
        requirements: %{}
      }
    end

    %TaskGraph{
      tasks: %{
        "a" => task.("a", [], ["b", "c"]),
        "b" => task.("b", ["a"], []),
        "c" => task.("c", ["a"], [])
      }
    }
  end

  defp start(opts) do
    defaults = [
      graph: graph(),
      run_id: "run-#{System.unique_integer([:positive])}",
      session_id: "sess-#{System.unique_integer([:positive])}",
      plugin: AssignRecordingPlugin,
      failure_strategy: :continue_all,
      context: %{test_pid: self()}
    ]

    {:ok, pid} = Scheduler.start_link(Keyword.merge(defaults, opts))
    pid
  end

  defp done(task_id, agent_id),
    do: %{task_id: task_id, status: :done, agent_id: agent_id, duration_ms: 5}

  defp lease(task_id, agent_id),
    do: %{task_id: task_id, agent_id: agent_id, assigned_at: DateTime.utc_now()}

  defp loader(results, leases), do: {Loader, :load, [%{results: results, leases: leases}]}

  describe ":state_loader" do
    test "finished tasks stay finished and leased tasks stay on their agent" do
      pid = start(state_loader: loader([done("a", "agent-1")], [lease("b", "agent-1")]))

      status = Scheduler.status(pid)
      assert status.tasks["a"].status == :done
      assert %{status: :running, assigned_to: "agent-1"} = status.tasks["b"]
      assert status.tasks["c"].status == :pending
      assert status.agents == %{"agent-1" => "b"}
      assert status.frontier == MapSet.new(["c"])

      # The leased task is not handed to anyone else, and its agent's result
      # passes the strict ACK.
      assert {:ok, %{task_id: "c"}} = Scheduler.request_task(pid, "agent-2")
      assert :no_task = Scheduler.request_task(pid, "agent-3")
      assert {:ok, :running} = Scheduler.report_result(pid, "b", "agent-1", {:success, 0})
    end

    test "a lease for a task that already has a result is ignored" do
      pid = start(state_loader: loader([done("a", "agent-1")], [lease("a", "agent-9")]))

      status = Scheduler.status(pid)
      assert %{status: :done, assigned_to: nil} = status.tasks["a"]
      assert status.agents == %{}
    end

    test "a persisted result wins over a rehydrate_from entry for the same task" do
      failed = %{task_id: "a", status: :failed, agent_id: "agent-2", duration_ms: 1}

      pid =
        start(state_loader: loader([done("a", "agent-1")], []), rehydrate_from: [failed])

      assert Scheduler.status(pid).tasks["a"].status == :done
    end

    test "a load that fails and then succeeds restores the run" do
      counter = :atomics.new(1, [])
      state = %{results: [done("a", "agent-1")], leases: [lease("b", "agent-1")]}

      pid =
        start(
          state_loader: {Loader, :flaky, [counter, 2, state]},
          state_load_backoff_ms: [10, 10, 10]
        )

      status = Scheduler.status(pid)
      assert :atomics.get(counter, 1) == 3
      assert status.tasks["a"].status == :done
      assert %{status: :running, assigned_to: "agent-1"} = status.tasks["b"]
      # Neither the finished task nor the leased one is handed out again.
      assert {:ok, %{task_id: "c"}} = Scheduler.request_task(pid, "agent-2")
      assert :no_task = Scheduler.request_task(pid, "agent-3")
      assert {:ok, :running} = Scheduler.report_result(pid, "b", "agent-1", {:success, 0})
    end

    test "a load that keeps failing stops the scheduler instead of booting from the graph" do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        "restore-test-#{inspect(ref)}",
        [:dxcore, :scheduler, :state_load_failed],
        fn _event, _measure, meta, _ ->
          send(test_pid, {:state_load_failed, meta.run_id, meta.final})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("restore-test-#{inspect(ref)}") end)
      Process.flag(:trap_exit, true)

      for loader <- [{Loader, :raises, []}, {Loader, :bad_shape, []}, :not_an_mfa] do
        run_id = "run-#{System.unique_integer([:positive])}"
        pid = start(run_id: run_id, state_loader: loader, state_load_backoff_ms: [10])

        assert_receive {:EXIT, ^pid, {:shutdown, {:state_load_failed, _reason}}}, 1_000
        assert_received {:state_load_failed, ^run_id, false}
        assert_received {:state_load_failed, ^run_id, true}
      end
    end

    test "is restarted only on a crash, so a scheduler that gives up does not crash-loop" do
      assert %{restart: :transient} = Scheduler.child_spec(graph: graph())
    end
  end

  describe "an agent that reports a result holds no other task" do
    test "a task pushed to it while it was busy goes back to the frontier" do
      pid = start([])
      {:ok, %{task_id: "a"}} = Scheduler.request_task(pid, "agent-1")
      {:ok, :running} = Scheduler.report_result(pid, "a", "agent-1", {:success, 0})
      {:ok, %{task_id: "b"}} = Scheduler.request_task(pid, "agent-1")
      # agent-1 reconnects mid-task and announces itself: it is handed c too,
      # which it ignores while b runs.
      {:ok, %{task_id: "c"}} = Scheduler.request_task(pid, "agent-1")

      {:ok, :running} = Scheduler.report_result(pid, "b", "agent-1", {:success, 0})

      status = Scheduler.status(pid)
      assert %{status: :pending, assigned_to: nil} = status.tasks["c"]
      assert status.frontier == MapSet.new(["c"])
      assert {:ok, %{task_id: "c"}} = Scheduler.request_task(pid, "agent-2")
    end

    test "even when its result is rejected" do
      pid = start(state_loader: loader([done("a", "agent-1")], [lease("b", "agent-1")]))
      {:ok, %{task_id: "c"}} = Scheduler.request_task(pid, "agent-2")

      # agent-2 reports b, which is agent-1's: rejected, and agent-2 is idle,
      # so the c it was holding is free again.
      assert {:error, :not_assigned} = Scheduler.report_result(pid, "b", "agent-2", {:success, 0})

      status = Scheduler.status(pid)
      assert %{status: :running, assigned_to: "agent-1"} = status.tasks["b"]
      assert %{status: :pending, assigned_to: nil} = status.tasks["c"]
    end
  end

  describe "restored leases" do
    test "an absent agent's lease is released after the grace window; a present one's is kept" do
      topic = "agent:org:#{System.unique_integer([:positive])}"
      :persistent_term.put({Endpoint, topic}, self())
      on_exit(fn -> :persistent_term.erase({Endpoint, topic}) end)

      pid =
        start(
          state_loader:
            loader([done("a", "agent-1")], [lease("b", "agent-1"), lease("c", "agent-2")]),
          lease_grace_ms: 30,
          context: %{
            test_pid: self(),
            endpoint: Endpoint,
            agent_topic: topic,
            agent_lister: fn _state -> [%AgentInfo{agent_id: "agent-1"}] end
          }
        )

      assert_receive {:broadcast, ^topic, "tasks_available", %{scheduler_pid: ^pid}}, 1_000

      status = Scheduler.status(pid)
      assert %{status: :running, assigned_to: "agent-1"} = status.tasks["b"]
      assert %{status: :pending, assigned_to: nil} = status.tasks["c"]
      assert status.agents == %{"agent-1" => "b"}
      assert status.frontier == MapSet.new(["c"])
    end
  end

  describe "hold_agent/2" do
    # The agents connected right now, as the coordinator's agent lister sees
    # them; the test changes it as agents come and go.
    defp agents_present(key, agent_ids),
      do: :persistent_term.put(key, Enum.map(agent_ids, &%AgentInfo{agent_id: &1}))

    # Also forwards this scheduler's `[:dxcore, :scheduler, :held_leases_checked]`
    # events as `{:checked, metadata}`: the proof that a lease check ran, and
    # what it decided.
    defp start_with_present_agents(opts) do
      key = {__MODULE__, :present, make_ref()}
      agents_present(key, [])
      on_exit(fn -> :persistent_term.erase(key) end)

      run_id = "run-#{System.unique_integer([:positive])}"
      test_pid = self()
      handler = "held-leases-#{run_id}"

      :telemetry.attach(
        handler,
        [:dxcore, :scheduler, :held_leases_checked],
        fn
          _event, _measurements, %{run_id: ^run_id} = meta, _ -> send(test_pid, {:checked, meta})
          _event, _measurements, _meta, _ -> :ok
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      context = %{test_pid: self(), agent_lister: fn _state -> :persistent_term.get(key) end}
      opts = opts |> Keyword.put(:context, context) |> Keyword.put(:run_id, run_id)
      {start(opts), key}
    end

    test "keeps a dropped agent's task on it for the window, then releases it if it is absent" do
      {pid, _key} = start_with_present_agents(lease_grace_ms: 300)
      {:ok, %{task_id: "a"}} = Scheduler.request_task(pid, "agent-1")

      :ok = Scheduler.hold_agent(pid, "agent-1")
      assert %{status: :running, assigned_to: "agent-1"} = Scheduler.status(pid).tasks["a"]
      # Nobody else is handed the task while its agent may still run it.
      assert :no_task = Scheduler.request_task(pid, "agent-2")
      refute_received {:released, "a", _}

      assert_receive {:released, "a", "agent-1"}, 1_000
      assert %{status: :pending, assigned_to: nil} = Scheduler.status(pid).tasks["a"]
      assert {:ok, %{task_id: "a"}} = Scheduler.request_task(pid, "agent-2")
    end

    test "an agent that is back when the window ends keeps its task" do
      {pid, key} = start_with_present_agents(lease_grace_ms: 50)
      {:ok, %{task_id: "a"}} = Scheduler.request_task(pid, "agent-1")
      :ok = Scheduler.hold_agent(pid, "agent-1")
      agents_present(key, ["agent-1"])

      assert_receive {:checked, %{released: [], kept: ["a"]}}, 1_000
      refute_received {:released, "a", _}
      assert {:ok, :running} = Scheduler.report_result(pid, "a", "agent-1", {:success, 0})
    end

    test "a lease held during another lease's window gets a full window of its own" do
      # b is restored on absent agent-1 when the scheduler starts; c is held
      # for agent-2 part-way through b's window.
      {pid, _key} =
        start_with_present_agents(
          lease_grace_ms: 500,
          state_loader: loader([done("a", "agent-0")], [lease("b", "agent-1")])
        )

      {:ok, %{task_id: "c"}} = Scheduler.request_task(pid, "agent-2")
      # Not a synchronization point: the clock moving on is what gives c a
      # later deadline than b, which is the case under test.
      Process.sleep(100)
      held_at = System.monotonic_time(:millisecond)
      :ok = Scheduler.hold_agent(pid, "agent-2")

      # b's window ends first; c is still in its own window then.
      assert_receive {:checked, %{released: ["b"], waiting: ["c"]}}, 1_000
      assert %{status: :running, assigned_to: "agent-2"} = Scheduler.status(pid).tasks["c"]

      assert_receive {:checked, %{released: ["c"], checked_at: released_at}}, 1_000
      assert released_at >= held_at + 500
      assert_received {:released, "c", "agent-2"}
    end

    test "a held task that finished is not released" do
      {pid, _key} = start_with_present_agents(lease_grace_ms: 50)
      {:ok, %{task_id: "a"}} = Scheduler.request_task(pid, "agent-1")
      :ok = Scheduler.hold_agent(pid, "agent-1")
      {:ok, :running} = Scheduler.report_result(pid, "a", "agent-1", {:success, 0})

      assert_receive {:checked, %{released: [], kept: [], waiting: []}}, 1_000
      refute_received {:released, _, _}
      assert Scheduler.status(pid).tasks["a"].status == :done
    end
  end

  describe "on_task_assigned" do
    test "is called with the task and the agent it was handed to" do
      pid = start([])
      {:ok, _} = Scheduler.request_task(pid, "agent-7", %AgentInfo{agent_id: "agent-7"})
      assert_receive {:assigned, "a", "agent-7", "agent-7"}
    end
  end

  describe "offline_summary/4" do
    test "summarizes a graph with results applied, without a scheduler" do
      failed = %{task_id: "b", status: :failed, agent_id: "agent-2", duration_ms: 3}

      summary =
        Scheduler.offline_summary(graph(), "run-1", [done("a", "agent-1"), failed], :fail_fast)

      assert summary.status == :failed
      assert summary.counts == %{passed: 1, failed: 1, skipped: 1, cached: 0}

      assert Enum.map(summary.tasks, &{&1.task_id, &1.status}) ==
               [{"a", :done}, {"b", :failed}, {"c", :skipped}]

      assert [%{task_id: "b", agent_id: "agent-2"}] = summary.failures
    end
  end

  describe "release_agent/3" do
    test "releases every task the agent holds except the one it names" do
      pid =
        start(
          state_loader:
            loader([done("a", "agent-1")], [lease("b", "agent-1"), lease("c", "agent-1")])
        )

      assert :ok = Scheduler.release_agent(pid, "agent-1", "b")
      status = Scheduler.status(pid)
      assert %{status: :running, assigned_to: "agent-1"} = status.tasks["b"]
      assert %{status: :pending, assigned_to: nil} = status.tasks["c"]
      assert status.frontier == MapSet.new(["c"])
      assert_receive {:released, "c", "agent-1"}
      refute_received {:released, "b", _}

      assert :ok = Scheduler.release_agent(pid, "agent-1")
      assert %{status: :pending, assigned_to: nil} = Scheduler.status(pid).tasks["b"]
      assert_receive {:released, "b", "agent-1"}
    end

    test "a released task is skipped, not re-run, once a fail_fast run has failed" do
      failed = %{task_id: "b", status: :failed, agent_id: "agent-2", duration_ms: 1}

      pid =
        start(
          failure_strategy: :fail_fast,
          state_loader: loader([done("a", "agent-1"), failed], [lease("c", "agent-1")])
        )

      assert %{status: :running} = Scheduler.status(pid).tasks["c"]
      :ok = Scheduler.release_agent(pid, "agent-1")

      status = Scheduler.status(pid)
      assert status.tasks["c"].status == :skipped
      assert status.frontier == MapSet.new()
      assert status.run_status == :failed
    end

    test "a malformed lease is ignored" do
      bad = [%{task_id: "b"}, %{task_id: "c", agent_id: 7}, :junk]
      pid = start(state_loader: loader([done("a", "agent-1")], bad))

      status = Scheduler.status(pid)
      assert status.tasks["b"].status == :pending
      assert status.tasks["c"].status == :pending
    end
  end
end

defmodule DxCore.Core.Scheduler.RestoreEnvTest do
  # Not async: it sets an app env every scheduler start reads.
  use ExUnit.Case, async: false

  alias DxCore.Core.Scheduler
  alias DxCore.Core.Scheduler.RestoreTest.Loader
  alias DxCore.Core.TaskGraph

  setup do
    start_supervised!({Registry, keys: :unique, name: DxCore.Core.SchedulerRegistry})
    :ok
  end

  test "a scheduler started without :state_loader uses the app env default" do
    previous = Application.get_env(:dxcore_core, :scheduler_state_loader)
    done = %{task_id: "a", status: :done, agent_id: "agent-1", duration_ms: 5}

    Application.put_env(
      :dxcore_core,
      :scheduler_state_loader,
      {Loader, :load, [%{results: [done], leases: []}]}
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:dxcore_core, :scheduler_state_loader, previous),
        else: Application.delete_env(:dxcore_core, :scheduler_state_loader)
    end)

    task = %TaskGraph.Task{
      task_id: "a",
      task: "test",
      package: "pkg",
      hash: "h",
      command: "true",
      deps: [],
      dependents: [],
      cache_status: :miss,
      cacheable: true,
      shard: nil,
      requirements: %{}
    }

    {:ok, pid} =
      Scheduler.start_link(
        graph: %TaskGraph{tasks: %{"a" => task}},
        run_id: "env-run",
        session_id: "env-sess",
        plugin: DxCore.Core.Scheduler.NullPlugin
      )

    assert Scheduler.status(pid).tasks["a"].status == :done
  end
end
