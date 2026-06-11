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

    test "drops tasks without package scripts" do
      json =
        Jason.encode!(%{
          "tasks" => [
            %{
              "taskId" => "ui#release-dev",
              "task" => "release-dev",
              "package" => "ui",
              "hash" => "abc",
              "command" => "pnpm release-dev"
            },
            %{
              "taskId" => "mobile#release-dev",
              "task" => "release-dev",
              "package" => "mobile",
              "hash" => "def",
              "command" => "<NONEXISTENT>"
            }
          ]
        })

      assert {:ok, [task]} = Turbo.parse_graph(json)
      assert task["taskId"] == "ui#release-dev"
    end

    test "prunes dropped <NONEXISTENT> task ids from surviving tasks' dependencies" do
      # A dropped no-op task that a real task depends on (e.g. github-workflows#deps
      # has no `deps` script -> <NONEXISTENT>, but #lint depends on it). The dropped
      # task is logically already-done, so it must be removed from #lint's deps —
      # otherwise the coordinator sees a dependency on a task not in the graph and
      # blocks #lint forever (#4154).
      json =
        Jason.encode!(%{
          "tasks" => [
            %{
              "taskId" => "wf#lint",
              "task" => "lint",
              "package" => "wf",
              "hash" => "h1",
              "command" => "prettier --check",
              "dependencies" => ["wf#deps", "cli#build"]
            },
            %{
              "taskId" => "wf#deps",
              "task" => "deps",
              "package" => "wf",
              "hash" => "h2",
              "command" => "<NONEXISTENT>",
              "dependencies" => []
            },
            %{
              "taskId" => "cli#build",
              "task" => "build",
              "package" => "cli",
              "hash" => "h3",
              "command" => "tsup",
              "dependencies" => []
            }
          ]
        })

      assert {:ok, tasks} = Turbo.parse_graph(json)
      ids = Enum.map(tasks, & &1["taskId"])
      assert "wf#deps" not in ids

      lint = Enum.find(tasks, &(&1["taskId"] == "wf#lint"))

      assert lint["dependencies"] == ["cli#build"],
             "expected the dropped wf#deps to be pruned from wf#lint deps, got #{inspect(lint["dependencies"])}"
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
