defmodule DxCore.Agents.BuildSystem.GenericTest do
  use ExUnit.Case, async: false

  alias DxCore.Agents.BuildSystem.Generic

  @fixture_path "test/fixtures/generic_graph.json"

  describe "parse_graph/1" do
    setup do
      json = File.read!(Path.join(File.cwd!(), @fixture_path))
      {:ok, json: json}
    end

    test "parses generic JSON into normalized task maps", %{json: json} do
      assert {:ok, tasks} = Generic.parse_graph(json)
      assert length(tasks) == 3

      by_id = Map.new(tasks, fn t -> {t["taskId"], t} end)

      migrate = by_id["migrate"]
      assert migrate["task"] == "migrate"
      assert migrate["package"] == "db"
      assert migrate["command"] == "mix ecto.migrate"
      assert migrate["dependencies"] == []
      assert migrate["hash"] == ""
      assert migrate["cache"] == %{"status" => "MISS"}
    end

    test "preserves dependencies", %{json: json} do
      assert {:ok, tasks} = Generic.parse_graph(json)
      by_id = Map.new(tasks, fn t -> {t["taskId"], t} end)

      assert by_id["migrate"]["dependencies"] == []
      assert by_id["seed"]["dependencies"] == ["migrate"]
      assert by_id["test-api"]["dependencies"] == ["migrate", "seed"]
    end

    test "computes dependents from dependencies (inverse mapping)", %{json: json} do
      assert {:ok, tasks} = Generic.parse_graph(json)
      by_id = Map.new(tasks, fn t -> {t["taskId"], t} end)

      assert Enum.sort(by_id["migrate"]["dependents"]) == Enum.sort(["seed", "test-api"])
      assert by_id["seed"]["dependents"] == ["test-api"]
      assert by_id["test-api"]["dependents"] == []
    end

    test "sets defaults for hash and cache", %{json: json} do
      assert {:ok, tasks} = Generic.parse_graph(json)

      Enum.each(tasks, fn task ->
        assert task["hash"] == ""
        assert task["cache"] == %{"status" => "MISS"}
      end)
    end

    test "handles empty tasks list" do
      json = ~s({"tasks":[]})
      assert {:ok, []} = Generic.parse_graph(json)
    end

    test "returns error for invalid JSON" do
      assert {:error, msg} = Generic.parse_graph("not json")
      assert msg =~ "Failed to parse Generic graph JSON:"
    end

    test "returns error for JSON missing tasks key" do
      assert {:error, "Unexpected Generic graph: missing tasks key"} =
               Generic.parse_graph(~s({"graph":{}}))
    end

    test "returns error when task missing required field taskId" do
      json =
        Jason.encode!(%{
          "tasks" => [
            %{
              "package" => "db",
              "task" => "migrate",
              "command" => "mix ecto.migrate",
              "dependencies" => []
            }
          ]
        })

      assert {:error, msg} = Generic.parse_graph(json)
      assert msg =~ "missing required field"
      assert msg =~ "taskId"
    end

    test "returns error when task missing required field package" do
      json =
        Jason.encode!(%{
          "tasks" => [
            %{
              "taskId" => "migrate",
              "task" => "migrate",
              "command" => "mix ecto.migrate",
              "dependencies" => []
            }
          ]
        })

      assert {:error, msg} = Generic.parse_graph(json)
      assert msg =~ "missing required field"
      assert msg =~ "package"
    end

    test "returns error when task missing required field task" do
      json =
        Jason.encode!(%{
          "tasks" => [
            %{
              "taskId" => "migrate",
              "package" => "db",
              "command" => "mix ecto.migrate",
              "dependencies" => []
            }
          ]
        })

      assert {:error, msg} = Generic.parse_graph(json)
      assert msg =~ "missing required field"
      assert msg =~ "task"
    end

    test "returns error when task missing required field command" do
      json =
        Jason.encode!(%{
          "tasks" => [
            %{"taskId" => "migrate", "package" => "db", "task" => "migrate", "dependencies" => []}
          ]
        })

      assert {:error, msg} = Generic.parse_graph(json)
      assert msg =~ "missing required field"
      assert msg =~ "command"
    end
  end

  describe "task_command/3" do
    setup do
      json = File.read!(Path.join(File.cwd!(), @fixture_path))
      Generic.parse_graph(json)
      :ok
    end

    test "returns executable and args from stored command" do
      {executable, args} = Generic.task_command("/work", "db", "migrate")

      assert String.ends_with?(executable, "mix")
      assert args == ["ecto.migrate"]
    end

    test "splits multi-arg command into executable and args" do
      {executable, args} = Generic.task_command("/work", "api", "test")

      assert String.ends_with?(executable, "cargo")
      assert args == ["test", "--release"]
    end
  end
end
