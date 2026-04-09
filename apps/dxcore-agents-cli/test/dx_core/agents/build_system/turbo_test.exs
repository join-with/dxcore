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
      assert task["command"] == "npx turbo run build --filter=ui"
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

  test "sets cacheable from resolvedTaskDefinition.cache" do
    json =
      Jason.encode!(%{
        "tasks" => [
          %{
            "taskId" => "ui#build",
            "task" => "build",
            "package" => "ui",
            "hash" => "abc",
            "resolvedTaskDefinition" => %{"cache" => false}
          },
          %{
            "taskId" => "ui#test",
            "task" => "test",
            "package" => "ui",
            "hash" => "def",
            "resolvedTaskDefinition" => %{"cache" => true}
          }
        ]
      })

    assert {:ok, [build, test]} = Turbo.parse_graph(json)
    assert build["cacheable"] == false
    assert test["cacheable"] == true
  end

  test "defaults cacheable to true when resolvedTaskDefinition is absent" do
    json =
      Jason.encode!(%{
        "tasks" => [
          %{"taskId" => "ui#dev", "task" => "dev", "package" => "ui", "hash" => "xyz"}
        ]
      })

    assert {:ok, [task]} = Turbo.parse_graph(json)
    assert task["cacheable"] == true
  end
end
