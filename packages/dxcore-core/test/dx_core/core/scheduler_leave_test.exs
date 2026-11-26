defmodule DxCore.Core.SchedulerLeaveTest do
  # `request_task/4` with `may_leave: true` (spec tests 2 and 3): the
  # scheduler asks `LeaveRule` inside its own call, so releases are decided
  # one at a time, and an agent kept as the spare takes a task that comes
  # back.
  use ExUnit.Case, async: true

  alias DxCore.Core.AgentInfo
  alias DxCore.Core.Scheduler
  alias DxCore.Core.TaskGraph

  @fixtures_dir Path.join([__DIR__, "..", "..", "fixtures"])
  @agents ["busy", "a", "b"]
  # The simple graph's root: the three other tasks wait on it.
  @root "@repo/ui#build"

  setup do
    start_supervised!({Registry, keys: :unique, name: DxCore.Core.SchedulerRegistry})
    {:ok, graph} = TaskGraph.parse(File.read!(Path.join(@fixtures_dir, "dry_run_simple.json")))
    %{graph: graph}
  end

  defp start(graph, context) do
    agents = Enum.map(@agents, &%AgentInfo{agent_id: &1, tags: %{}})

    {:ok, pid} =
      Scheduler.start_link(
        graph: graph,
        run_id: "run-#{System.unique_integer([:positive])}",
        session_id: "session-#{System.unique_integer([:positive])}",
        plugin: DxCore.Core.Scheduler.NullPlugin,
        context: Map.merge(%{early_leave: true, agent_lister: fn _state -> agents end}, context)
      )

    # "busy" runs the root; nothing else is ready until it ends.
    assert {:ok, %{task_id: @root}} = ask(pid, "busy")
    pid
  end

  defp ask(pid, agent_id),
    do: Scheduler.request_task(pid, agent_id, %AgentInfo{agent_id: agent_id}, may_leave: true)

  test "two idle agents asking at once: exactly one leaves, the other stays as the spare", %{
    graph: graph
  } do
    pid = start(graph, %{})
    me = self()

    # Both calls are in the scheduler's mailbox before it answers either.
    :sys.suspend(pid)

    for agent <- ["a", "b"],
        do: spawn_link(fn -> send(me, {agent, ask(pid, agent)}) end)

    wait_for_mailbox(pid, 2)
    :sys.resume(pid)

    answers =
      for _ <- 1..2 do
        receive do
          {agent, answer} -> {agent, answer}
        after
          5_000 -> flunk("no answer")
        end
      end

    assert answers |> Enum.map(&elem(&1, 1)) |> Enum.sort() ==
             [:no_task, {:leave, :no_more_work}]

    {left, _} = Enum.find(answers, &match?({_, {:leave, _}}, &1))
    # A released agent asking again gets the same answer.
    assert ask(pid, left) == {:leave, :no_more_work}
  end

  test "a task released after an agent left goes to the spare", %{graph: graph} do
    pid = start(graph, %{})

    assert ask(pid, "a") == {:leave, :no_more_work}
    assert ask(pid, "b") == :no_task

    # The holder's lease is released (it died): the root is ready again.
    :ok = Scheduler.release_agent(pid, "busy")
    assert {:ok, %{task_id: @root}} = ask(pid, "b")
  end

  test "without the run's early_leave the answer is :no_task, as before", %{graph: graph} do
    pid = start(graph, %{early_leave: false})
    assert ask(pid, "a") == :no_task
    assert ask(pid, "b") == :no_task
  end

  test "without may_leave the answer is :no_task, as before", %{graph: graph} do
    pid = start(graph, %{})
    assert Scheduler.request_task(pid, "a", %AgentInfo{agent_id: "a"}) == :no_task
    assert Scheduler.request_task(pid, "b", %AgentInfo{agent_id: "b"}) == :no_task
  end

  test "each release emits agent_released telemetry", %{graph: graph} do
    ref = :telemetry_test.attach_event_handlers(self(), [[:dxcore, :scheduler, :agent_released]])
    pid = start(graph, %{})

    assert ask(pid, "a") == {:leave, :no_more_work}

    assert_receive {[:dxcore, :scheduler, :agent_released], ^ref, %{count: 1},
                    %{agent_id: "a", reason: :no_more_work}}
  end

  defp wait_for_mailbox(pid, n) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, len} when len >= n ->
        :ok

      _ ->
        Process.sleep(5)
        wait_for_mailbox(pid, n)
    end
  end
end
