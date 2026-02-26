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

    test "sets empty command for all tasks", %{json: json} do
      {:ok, tasks} = Nx.parse_graph(json)

      Enum.each(tasks, fn task ->
        assert task["command"] == ""
      end)
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

  describe "task_command/3" do
    test "returns npx nx run command" do
      {executable, args} = Nx.task_command("/work", "myapp", "build")

      assert String.ends_with?(executable, "npx")
      assert args == ["nx", "run", "myapp:build"]
    end
  end
end
