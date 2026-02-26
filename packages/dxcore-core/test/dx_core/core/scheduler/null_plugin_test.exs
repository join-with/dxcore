defmodule DxCore.Core.Scheduler.NullPluginTest do
  use ExUnit.Case, async: true

  alias DxCore.Core.AgentInfo
  alias DxCore.Core.Scheduler.NullPlugin
  alias DxCore.Core.Scheduler.TaskState
  alias DxCore.Core.TaskGraph

  describe "select_task/3" do
    test "returns first task from list" do
      task1 = %TaskState{task_id: "a#build", status: :pending}
      task2 = %TaskState{task_id: "b#build", status: :pending}

      assert NullPlugin.select_task([task1, task2], %AgentInfo{}, %{}) == task1
    end

    test "returns nil for empty list" do
      assert NullPlugin.select_task([], %AgentInfo{}, %{}) == nil
    end

    test "ignores context parameter" do
      task = %TaskState{task_id: "a#build", status: :pending}
      context = %{tenant_id: "some-tenant"}

      assert NullPlugin.select_task([task], %AgentInfo{}, context) == task
    end
  end

  describe "expand_graph/2" do
    test "returns graph unchanged" do
      graph = %TaskGraph{tasks: %{"a" => %TaskGraph.Task{task_id: "a"}}}
      assert NullPlugin.expand_graph(graph, %{}) == graph
    end

    test "ignores context parameter" do
      graph = %TaskGraph{tasks: %{"a" => %TaskGraph.Task{task_id: "a"}}}
      assert NullPlugin.expand_graph(graph, %{tenant_id: "t1"}) == graph
    end
  end

  describe "on_task_complete/5" do
    test "returns :ok" do
      task = %TaskState{task_id: "a#build", status: :done}
      assert NullPlugin.on_task_complete(task, :success, 1234, %AgentInfo{}, %{}) == :ok
    end

    test "ignores context parameter" do
      task = %TaskState{task_id: "a#build", status: :done}

      assert NullPlugin.on_task_complete(task, :failed, 500, %AgentInfo{}, %{tenant_id: "t1"}) ==
               :ok
    end
  end
end
