defmodule DxCore.Agents.BuildSystem.TurboTest do
  use ExUnit.Case, async: true

  alias DxCore.Agents.BuildSystem.Turbo

  describe "parse_graph/1" do
    test "extracts tasks from turbo dry-run JSON" do
      json =
        ~s({"tasks":[{"taskId":"ui#build","task":"build","package":"ui","hash":"abc","command":"vite build","outputs":[],"dependencies":[],"dependents":["app#build"],"cache":{"status":"MISS"}}]})

      assert {:ok, [task]} = Turbo.parse_graph(json)
      assert task["taskId"] == "ui#build"
      assert task["package"] == "ui"
      assert task["task"] == "build"
      assert task["hash"] == "abc"
      assert task["command"] == "vite build"
      assert task["dependencies"] == []
      assert task["dependents"] == ["app#build"]
      assert task["cache"] == %{"status" => "MISS"}
    end

    test "handles empty tasks list" do
      assert {:ok, []} = Turbo.parse_graph(~s({"tasks":[]}))
    end

    test "returns error for invalid JSON" do
      assert {:error, msg} = Turbo.parse_graph("no json here")
      assert msg =~ "Failed to parse turbo JSON output:"
    end

    test "returns error for JSON without tasks key" do
      assert {:error, "Unexpected turbo output: missing tasks key"} =
               Turbo.parse_graph(~s({"packages":["a","b"]}))
    end
  end

  describe "task_command/3" do
    test "returns npx turbo command for package and task" do
      {executable, args} = Turbo.task_command("/work", "admin", "build")

      assert String.ends_with?(executable, "npx")
      assert args == ["turbo", "run", "build", "--filter=admin"]
    end
  end
end
