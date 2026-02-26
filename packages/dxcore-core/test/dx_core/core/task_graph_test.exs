defmodule DxCore.Core.TaskGraphTest do
  use ExUnit.Case, async: true

  alias DxCore.Core.TaskGraph

  @fixtures_path Path.expand("../../fixtures", __DIR__)

  defp read_fixture(name) do
    @fixtures_path
    |> Path.join(name)
    |> File.read!()
  end

  describe "parse/1" do
    test "parses simple JSON into task map with 4 tasks" do
      json = read_fixture("dry_run_simple.json")
      assert {:ok, %TaskGraph{tasks: tasks}} = TaskGraph.parse(json)
      assert map_size(tasks) == 4
      assert Map.has_key?(tasks, "@repo/ui#build")
      assert Map.has_key?(tasks, "admin#build")
      assert Map.has_key?(tasks, "api#build")
      assert Map.has_key?(tasks, "admin#test")
    end

    test "extracts dependencies correctly" do
      json = read_fixture("dry_run_simple.json")
      {:ok, %TaskGraph{tasks: tasks}} = TaskGraph.parse(json)

      assert tasks["@repo/ui#build"].deps == []
      assert tasks["admin#build"].deps == ["@repo/ui#build"]
      assert tasks["api#build"].deps == ["@repo/ui#build"]
      assert tasks["admin#test"].deps == ["admin#build"]
    end

    test "extracts package and task from taskId" do
      json = read_fixture("dry_run_simple.json")
      {:ok, %TaskGraph{tasks: tasks}} = TaskGraph.parse(json)

      ui_task = tasks["@repo/ui#build"]
      assert ui_task.package == "@repo/ui"
      assert ui_task.task == "build"

      admin_test = tasks["admin#test"]
      assert admin_test.package == "admin"
      assert admin_test.task == "test"
    end

    test "marks cache hits" do
      json = read_fixture("dry_run_with_cache_hits.json")
      {:ok, %TaskGraph{tasks: tasks}} = TaskGraph.parse(json)

      assert tasks["@repo/ui#build"].cache_status == :hit
      assert tasks["admin#build"].cache_status == :miss
      assert tasks["api#build"].cache_status == :miss
      assert tasks["admin#test"].cache_status == :miss
    end

    test "shard field defaults to nil when not present" do
      json = read_fixture("dry_run_simple.json")
      {:ok, %TaskGraph{tasks: tasks}} = TaskGraph.parse(json)

      Enum.each(tasks, fn {_id, task} ->
        assert task.shard == nil
      end)
    end

    test "returns error on invalid JSON" do
      assert {:error, _reason} = TaskGraph.parse("not valid json")
    end

    test "returns error when tasks key is missing" do
      assert {:error, :missing_tasks_key} = TaskGraph.parse(~s({"id": "no-tasks"}))
    end
  end

  describe "parse_shard/1" do
    test "returns nil for nil input" do
      assert TaskGraph.parse_shard(nil) == nil
    end

    test "parses decoded JSON map (primary format)" do
      assert TaskGraph.parse_shard(%{"index" => 1, "count" => 4}) == %{index: 1, count: 4}
      assert TaskGraph.parse_shard(%{"index" => 0, "count" => 3}) == %{index: 0, count: 3}
    end

    test "parses valid shard string (shorthand)" do
      assert TaskGraph.parse_shard("1/4") == %{index: 1, count: 4}
      assert TaskGraph.parse_shard("0/3") == %{index: 0, count: 3}
    end

    test "returns nil for invalid shard string" do
      assert TaskGraph.parse_shard("abc") == nil
      assert TaskGraph.parse_shard("1/") == nil
      assert TaskGraph.parse_shard("/4") == nil
      assert TaskGraph.parse_shard("a/b") == nil
    end

    test "returns nil for unrecognized types" do
      assert TaskGraph.parse_shard(42) == nil
      assert TaskGraph.parse_shard(%{"other" => "keys"}) == nil
    end
  end

  describe "initial_frontier/1" do
    test "returns tasks with no unmet dependencies" do
      json = read_fixture("dry_run_simple.json")
      {:ok, graph} = TaskGraph.parse(json)

      frontier = TaskGraph.initial_frontier(graph)

      assert MapSet.member?(frontier, "@repo/ui#build")
      assert MapSet.size(frontier) == 1
    end

    test "includes tasks whose deps are all cache hits" do
      json = read_fixture("dry_run_with_cache_hits.json")
      {:ok, graph} = TaskGraph.parse(json)

      frontier = TaskGraph.initial_frontier(graph)

      # @repo/ui#build is a HIT, so it's "done" -- not in frontier
      refute MapSet.member?(frontier, "@repo/ui#build")

      # admin#build and api#build depend only on @repo/ui#build (HIT), so they are frontier
      assert MapSet.member?(frontier, "admin#build")
      assert MapSet.member?(frontier, "api#build")

      # admin#test depends on admin#build which is MISS, so not frontier
      refute MapSet.member?(frontier, "admin#test")

      assert MapSet.size(frontier) == 2
    end
  end
end
