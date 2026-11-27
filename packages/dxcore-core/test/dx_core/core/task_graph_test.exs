defmodule DxCore.Core.TaskGraphTest do
  use ExUnit.Case, async: true

  alias DxCore.Core.TaskGraph
  alias DxCore.Core.TaskGraph.Task

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

    test "cacheable defaults to false when not specified" do
      json =
        Jason.encode!(%{
          "tasks" => [
            %{
              "taskId" => "a",
              "task" => "build",
              "package" => "x",
              "command" => "x",
              "dependencies" => []
            }
          ]
        })

      {:ok, %TaskGraph{tasks: tasks}} = TaskGraph.parse(json)
      assert tasks["a"].cacheable == false
    end

    test "cacheable is true when explicitly set" do
      json =
        Jason.encode!(%{
          "tasks" => [
            %{
              "taskId" => "a",
              "task" => "build",
              "package" => "x",
              "command" => "x",
              "dependencies" => [],
              "cacheable" => true
            }
          ]
        })

      {:ok, %TaskGraph{tasks: tasks}} = TaskGraph.parse(json)
      assert tasks["a"].cacheable == true
    end

    test "cacheable is false when explicitly set" do
      json =
        Jason.encode!(%{
          "tasks" => [
            %{
              "taskId" => "a",
              "task" => "build",
              "package" => "x",
              "command" => "x",
              "dependencies" => [],
              "cacheable" => false
            }
          ]
        })

      {:ok, %TaskGraph{tasks: tasks}} = TaskGraph.parse(json)
      assert tasks["a"].cacheable == false
    end

    test "returns error on invalid JSON" do
      assert {:error, _reason} = TaskGraph.parse("not valid json")
    end

    test "returns error when tasks key is missing" do
      assert {:error, "the graph has no tasks list"} = TaskGraph.parse(~s({"id": "no-tasks"}))
      assert {:error, "the graph has no tasks list"} = TaskGraph.parse(~s({"tasks": {}}))
    end

    test "derives each task's dependents from the others' dependencies" do
      {:ok, %TaskGraph{tasks: tasks}} = TaskGraph.parse(read_fixture("dry_run_simple.json"))

      assert Enum.sort(tasks["@repo/ui#build"].dependents) == ["admin#build", "api#build"]
      assert tasks["admin#build"].dependents == ["admin#test"]
      assert tasks["admin#test"].dependents == []
    end

    test "parses requirements field from tasks" do
      json = read_fixture("dry_run_with_requirements.json")
      {:ok, %TaskGraph{tasks: tasks}} = TaskGraph.parse(json)

      assert tasks["cli#build"].requirements == %{"zig" => "true"}

      assert tasks["cli#release-dev"].requirements == %{
               "zig" => "true",
               "github-release" => "true"
             }
    end

    test "defaults requirements to empty map when not present" do
      json = read_fixture("dry_run_with_requirements.json")
      {:ok, %TaskGraph{tasks: tasks}} = TaskGraph.parse(json)

      assert tasks["web#build"].requirements == %{}
    end

    test "existing fixtures have empty requirements by default" do
      json = read_fixture("dry_run_simple.json")
      {:ok, %TaskGraph{tasks: tasks}} = TaskGraph.parse(json)

      assert tasks["@repo/ui#build"].requirements == %{}
    end
  end

  describe "parse/1 refuses a graph that is not dxcore's format" do
    defp t(id, extra \\ %{}),
      do:
        Map.merge(
          %{
            "taskId" => id,
            "task" => "build",
            "package" => "p",
            "hash" => "h",
            "command" => "npx turbo run build --filter=p",
            "dependencies" => [],
            "cache" => %{"status" => "MISS"},
            "cacheable" => true,
            "requirements" => %{}
          },
          extra
        )

    defp refused(tasks), do: TaskGraph.parse(Jason.encode!(%{"tasks" => tasks}))

    test "a graph with every field of the format passes" do
      assert {:ok, %TaskGraph{tasks: tasks}} =
               refused([
                 t("a"),
                 t("b", %{
                   "dependencies" => ["a"],
                   "shard" => %{"index" => 1, "count" => 2},
                   "requirements" => %{"e2e" => "true"}
                 })
               ])

      assert tasks["a"].dependents == ["b"]
      assert tasks["b"].shard == %{index: 1, count: 2}
    end

    test "a field outside the agent protocol's taskFields" do
      assert {:error, "task a: unknown fields dependents, outputs"} =
               refused([t("a", %{"dependents" => [], "outputs" => []})])
    end

    test "a task that is not an object, or has no usable taskId" do
      assert {:error, "a task is not an object"} = refused([1])
      assert {:error, "a task has no taskId"} = refused([Map.delete(t("a"), "taskId")])
      assert {:error, "a task's taskId is not a non-empty string"} = refused([t("")])
      assert {:error, "a task's taskId is not a non-empty string"} = refused([t(7)])
    end

    test "a task without the task, package or command an agent runs" do
      for field <- ["task", "package", "command"] do
        assert {:error, "task a: no " <> ^field} = refused([Map.delete(t("a"), field)])
      end
    end

    test "an id in the graph twice" do
      assert {:error, "task a is in the graph twice"} = refused([t("a"), t("a")])
    end

    test "a string field of the wrong type, empty or too long" do
      assert {:error, "task a: task is not a string"} = refused([t("a", %{"task" => 1})])
      assert {:error, "task a: package is empty"} = refused([t("a", %{"package" => ""})])
      assert {:error, "task a: command is empty"} = refused([t("a", %{"command" => ""})])
      assert {:error, "task a: hash is not a string"} = refused([t("a", %{"hash" => nil})])

      assert {:error, "task a: taskId is 1025 bytes, over the cap of 1024"} =
               refused([t("a", %{"taskId" => String.duplicate("a", 1025)})])
               |> then(fn {:error, m} ->
                 {:error, String.replace(m, ~r/^task a+:/, "task a:")}
               end)

      assert {:error, "task a: command is 8193 bytes, over the cap of 8192"} =
               refused([t("a", %{"command" => String.duplicate("x", 8193)})])
    end

    test "dependencies that are not distinct ids of tasks in the graph" do
      assert {:error, "task a: dependencies is not a list"} =
               refused([t("a", %{"dependencies" => "b"})])

      assert {:error, "task a: a dependency is not a non-empty string"} =
               refused([t("a", %{"dependencies" => [1]})])

      assert {:error, "task b: lists a dependency twice"} =
               refused([t("a"), t("b", %{"dependencies" => ["a", "a"]})])

      assert {:error, "task a: dependency gone is not in the graph"} =
               refused([t("a", %{"dependencies" => ["gone"]})])

      assert {:error, "task a: 5001 dependencies, over the cap of 5000"} =
               refused([t("a", %{"dependencies" => Enum.map(1..5001, &"d#{&1}")})])
    end

    test "a cycle, a self-dependency included" do
      assert {:error, "the graph has a cycle: 3 tasks never get ready, among them a"} =
               refused([
                 t("a", %{"dependencies" => ["c"]}),
                 t("b", %{"dependencies" => ["a"]}),
                 t("c", %{"dependencies" => ["b"]}),
                 t("ok")
               ])

      assert {:error, "the graph has a cycle: 1 tasks never get ready, among them s"} =
               refused([t("s", %{"dependencies" => ["s"]})])
    end

    test "a cache, cacheable or shard of the wrong shape" do
      assert {:error, ~s(task a: cache is not {"status": "HIT" or "MISS"})} =
               refused([t("a", %{"cache" => %{"status" => "MISS", "local" => false}})])

      assert {:error, ~s(task a: cache is not {"status": "HIT" or "MISS"})} =
               refused([t("a", %{"cache" => %{"status" => "SKIP"}})])

      assert {:error, "task a: cacheable is not a boolean"} =
               refused([t("a", %{"cacheable" => "yes"})])

      assert {:error, "task a: shard is not a shard"} = refused([t("a", %{"shard" => "x"})])
    end

    test "requirements that are not a small map of strings" do
      assert {:error, "task a: requirements is not an object"} =
               refused([t("a", %{"requirements" => []})])

      assert {:error, "task a: a requirement is not a string of at most 1024 bytes"} =
               refused([t("a", %{"requirements" => %{"docker" => true}})])

      assert {:error, "task a: 33 requirements, over the cap of 32"} =
               refused([t("a", %{"requirements" => Map.new(1..33, &{"k#{&1}", "v"})})])
    end

    test "more tasks or edges than a graph may hold" do
      assert {:error, "the graph has 20001 tasks, over the cap of 20000"} =
               refused(Enum.map(1..20_001, &t("t#{&1}")))

      roots = Enum.map(1..100, &t("r#{&1}"))
      ids = Enum.map(roots, & &1["taskId"])
      wide = Enum.map(1..4001, &t("w#{&1}", %{"dependencies" => ids}))

      assert {:error, "the graph has 400100 dependency edges, over the cap of 400000"} =
               refused(roots ++ wide)
    end
  end

  describe "serialize/1" do
    test "serialize/1 round-trips through parse/1" do
      json = read_fixture("dry_run_simple.json")
      {:ok, original} = TaskGraph.parse(json)

      serialized_json = original |> TaskGraph.serialize() |> Jason.encode!()
      {:ok, round_tripped} = TaskGraph.parse(serialized_json)

      assert MapSet.equal?(
               MapSet.new(Map.keys(original.tasks)),
               MapSet.new(Map.keys(round_tripped.tasks))
             )

      for {id, original_task} <- original.tasks do
        rt = round_tripped.tasks[id]
        assert rt.task_id == original_task.task_id
        assert rt.task == original_task.task
        assert rt.package == original_task.package
        assert rt.hash == original_task.hash
        assert rt.command == original_task.command
        assert rt.deps == original_task.deps
        assert Enum.sort(rt.dependents) == Enum.sort(original_task.dependents)
        assert rt.cache_status == original_task.cache_status
        assert rt.cacheable == original_task.cacheable
        assert rt.shard == original_task.shard
        assert rt.requirements == original_task.requirements
      end
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
