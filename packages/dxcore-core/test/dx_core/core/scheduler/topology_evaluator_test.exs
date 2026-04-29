defmodule DxCore.Core.Scheduler.TopologyEvaluatorTest do
  use ExUnit.Case, async: true

  alias DxCore.Core.AgentInfo
  alias DxCore.Core.Scheduler.TopologyEvaluator

  defmodule StubPlugin do
    @behaviour DxCore.Core.SchedulerPlugin

    def expand_graph(graph, _ctx), do: graph
    def select_task(_frontier, _agent, _ctx), do: nil
    def on_task_complete(_t, _r, _d, _a, _c), do: :ok

    def evaluate_assignability(frontier_tasks, connected_agents) do
      # Test plugin: any task whose `requirements[:tag]` doesn't match any
      # connected agent's tag is unassignable.
      Enum.split_with(frontier_tasks, fn task ->
        required = task.requirements["tag"]

        required == nil or
          Enum.any?(connected_agents, fn a -> a.tags["tag"] == required end)
      end)
    end
  end

  defp base_state(extra_context) do
    %{
      session_id: "session-1",
      run_id: "run-1",
      plugin: StubPlugin,
      context: extra_context,
      tasks: %{
        "t1" => %{
          task_id: "t1",
          status: :pending,
          requirements: %{"tag" => "zig"},
          dependents: [],
          exit_code: nil
        },
        "t2" => %{
          task_id: "t2",
          status: :pending,
          requirements: %{},
          dependents: [],
          exit_code: nil
        }
      },
      frontier: MapSet.new(["t1", "t2"]),
      failure_strategy: :continue_all,
      failed_fast: false,
      topology_check: "infer",
      topology_settled: false
    }
  end

  describe "evaluate_assignability/1 with agent_lister" do
    test "calls agent_lister with state and passes result to plugin" do
      pid = self()

      lister = fn state ->
        send(pid, {:lister_called, state.session_id})
        [%AgentInfo{agent_id: "a1", tags: %{"tag" => "zig"}}]
      end

      state = base_state(%{agent_lister: lister})

      result = TopologyEvaluator.evaluate_assignability(state)

      assert_received {:lister_called, "session-1"}
      assert result.tasks["t1"].status == :pending
      assert result.tasks["t2"].status == :pending
    end

    test "missing agent_lister yields empty agent list (tasks failed if requirements unmet)" do
      state = base_state(%{})

      result = TopologyEvaluator.evaluate_assignability(state)

      # t1 requires tag=zig, no agents present → :failed
      assert result.tasks["t1"].status == :failed
      # t2 has no requirements → still pending
      assert result.tasks["t2"].status == :pending
    end
  end

  describe "explicit topology mode (Mode A) with agent_lister" do
    test "counts agents from agent_lister to determine if expected reached" do
      lister = fn _state ->
        [
          %AgentInfo{agent_id: "a1", tags: %{}},
          %AgentInfo{agent_id: "a2", tags: %{}}
        ]
      end

      state =
        base_state(%{agent_lister: lister})
        |> Map.merge(%{
          topology_check: "explicit",
          expected_agents: 2,
          topology_timer: nil
        })

      result = TopologyEvaluator.evaluate(state)

      assert result.topology_settled == true
    end

    test "stays unsettled when count below expected" do
      lister = fn _state -> [%AgentInfo{agent_id: "a1", tags: %{}}] end

      state =
        base_state(%{agent_lister: lister})
        |> Map.merge(%{
          topology_check: "explicit",
          expected_agents: 2,
          topology_timer: nil
        })

      result = TopologyEvaluator.evaluate(state)

      assert result.topology_settled == false
    end
  end
end
