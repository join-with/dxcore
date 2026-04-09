defmodule DxCore.Agents.BuildSystem.NxTest do
  use ExUnit.Case, async: true

  alias DxCore.Agents.BuildSystem.Nx

  @fixture_path "test/fixtures/nx_graph.json"

  describe "parse_graph/1" do
    setup do
      json = File.read!(Path.join(File.cwd!(), @fixture_path))
      {:ok, json: json}
    end

    test "parses Nx graph into normalized task maps", %{json: json} do
      assert {:ok, tasks} = Nx.parse_graph(json)
      assert length(tasks) == 3

      by_id = Map.new(tasks, fn t -> {t["taskId"], t} end)

      lib_build = by_id["mylib:build"]
      assert lib_build["task"] == "build"
      assert lib_build["package"] == "mylib"
      assert lib_build["hash"] == ""
      assert lib_build["dependencies"] == []
      assert "myapp:build" in lib_build["dependents"]
    end

    test "computes dependents by inverting dependencies", %{json: json} do
      {:ok, tasks} = Nx.parse_graph(json)
      by_id = Map.new(tasks, fn t -> {t["taskId"], t} end)

      assert by_id["mylib:build"]["dependents"] == ["myapp:build"]
      assert by_id["myapp:build"]["dependents"] == ["myapp:test"]
      assert by_id["myapp:test"]["dependents"] == []
    end

    test "sets cache status to MISS for all tasks", %{json: json} do
      {:ok, tasks} = Nx.parse_graph(json)

      Enum.each(tasks, fn task ->
        assert task["cache"] == %{"status" => "MISS"}
      end)
    end

    test "populates command field with npx nx run", %{json: json} do
      {:ok, tasks} = Nx.parse_graph(json)
      by_id = Map.new(tasks, fn t -> {t["taskId"], t} end)

      assert by_id["mylib:build"]["command"] == "npx nx run mylib:build"
      assert by_id["myapp:test"]["command"] == "npx nx run myapp:test"
    end

    test "reads cacheable from task cache field", %{json: json} do
      {:ok, tasks} = Nx.parse_graph(json)

      Enum.each(tasks, fn task ->
        assert task["cacheable"] == true
      end)
    end

    test "defaults cacheable to false when cache field is absent" do
      json =
        Jason.encode!(%{
          "tasks" => %{
            "tasks" => %{
              "mylib:build" => %{
                "id" => "mylib:build",
                "target" => %{"project" => "mylib", "target" => "build"}
              }
            },
            "dependencies" => %{"mylib:build" => []}
          }
        })

      assert {:ok, [task]} = Nx.parse_graph(json)
      assert task["cacheable"] == false
    end

    test "handles empty graph" do
      json = ~s({"tasks":{"tasks":{},"dependencies":{}}})
      assert {:ok, []} = Nx.parse_graph(json)
    end

    test "returns error for invalid JSON" do
      assert {:error, msg} = Nx.parse_graph("not json")
      assert msg =~ "Failed to parse Nx graph JSON:"
    end

    test "returns error for JSON missing tasks key" do
      assert {:error, "Unexpected Nx graph output: missing tasks field"} =
               Nx.parse_graph(~s({"graph":{}}))
    end
  end
end
