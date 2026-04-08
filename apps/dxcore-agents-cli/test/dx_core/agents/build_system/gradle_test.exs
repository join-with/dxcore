defmodule DxCore.Agents.BuildSystem.GradleTest do
  use ExUnit.Case, async: true

  alias DxCore.Agents.BuildSystem.Gradle

  @fixture_path "test/fixtures/gradle_graph.json"

  describe "parse_graph/1" do
    setup do
      json = File.read!(Path.join(File.cwd!(), @fixture_path))
      {:ok, json: json}
    end

    test "parses Gradle JSON into normalized task maps", %{json: json} do
      assert {:ok, tasks} = Gradle.parse_graph(json)
      # Full graph: 36 tasks (9 cacheable + 27 non-cacheable)
      assert length(tasks) == 36

      by_id = Map.new(tasks, fn t -> {t["taskId"], t} end)

      compile = by_id[":lib-core:compileJava"]
      assert compile["task"] == "compileJava"
      assert compile["package"] == "lib-core"
      assert compile["command"] == "./gradlew :lib-core:compileJava"
      assert compile["dependencies"] == []
      assert compile["hash"] == ""
      assert compile["cache"] == %{"status" => "MISS"}
    end

    test "preserves dependency chains", %{json: json} do
      assert {:ok, tasks} = Gradle.parse_graph(json)
      by_id = Map.new(tasks, fn t -> {t["taskId"], t} end)

      assert by_id[":lib-core:compileJava"]["dependencies"] == []
      assert ":lib-core:compileJava" in by_id[":lib-core:compileTestJava"]["dependencies"]
      assert ":lib-core:compileJava" in by_id[":lib-core:classes"]["dependencies"]
      assert ":lib-core:compileJava" in by_id[":lib-api:compileJava"]["dependencies"]
      assert ":lib-api:compileJava" in by_id[":app:compileJava"]["dependencies"]
      assert ":app:assemble" in by_id[":app:build"]["dependencies"]
      assert ":app:check" in by_id[":app:build"]["dependencies"]
    end

    test "computes dependents from dependencies", %{json: json} do
      assert {:ok, tasks} = Gradle.parse_graph(json)
      by_id = Map.new(tasks, fn t -> {t["taskId"], t} end)

      # lib-core:compileJava is depended on by classes, jar, compileTestJava, and cross-module
      dependents = by_id[":lib-core:compileJava"]["dependents"]
      assert ":lib-core:classes" in dependents
      assert ":lib-core:compileTestJava" in dependents
      assert ":lib-api:compileJava" in dependents

      # build is a leaf — no dependents
      assert by_id[":app:build"]["dependents"] == []
    end

    test "preserves cacheable flag", %{json: json} do
      assert {:ok, tasks} = Gradle.parse_graph(json)
      by_id = Map.new(tasks, fn t -> {t["taskId"], t} end)

      # Cacheable tasks
      assert by_id[":lib-core:compileJava"]["cacheable"] == true
      assert by_id[":lib-core:test"]["cacheable"] == true

      # Non-cacheable tasks
      assert by_id[":lib-core:build"]["cacheable"] == false
      assert by_id[":lib-core:jar"]["cacheable"] == false
      assert by_id[":lib-core:processResources"]["cacheable"] == false
    end

    test "sets defaults for hash and cache", %{json: json} do
      assert {:ok, tasks} = Gradle.parse_graph(json)

      Enum.each(tasks, fn task ->
        assert task["hash"] == ""
        assert task["cache"] == %{"status" => "MISS"}
      end)
    end

    test "handles empty tasks list" do
      assert {:ok, []} = Gradle.parse_graph(~s({"tasks":[]}))
    end

    test "returns error for invalid JSON" do
      assert {:error, msg} = Gradle.parse_graph("not json")
      assert msg =~ "Failed to parse Gradle graph JSON:"
    end

    test "returns error for JSON missing tasks key" do
      assert {:error, "Unexpected Gradle graph: missing tasks key"} =
               Gradle.parse_graph(~s({"graph":{}}))
    end

    test "returns error when task missing required field" do
      json =
        Jason.encode!(%{
          "tasks" => [
            %{
              "package" => "lib-core",
              "task" => "compileJava",
              "command" => "./gradlew :lib-core:compileJava",
              "dependencies" => []
            }
          ]
        })

      assert {:error, msg} = Gradle.parse_graph(json)
      assert msg =~ "missing required field"
      assert msg =~ "taskId"
    end
  end

  describe "task_command/3" do
    test "returns gradlew with task path from work_dir" do
      {executable, args} = Gradle.task_command("/my/project", "lib-core", "compileJava")
      assert executable == "/my/project/gradlew"
      assert args == [":lib-core:compileJava"]
    end
  end
end
