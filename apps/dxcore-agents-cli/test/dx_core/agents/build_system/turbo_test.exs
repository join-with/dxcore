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
      assert task["command"] == "npx turbo run build --filter=ui --log-order=stream"
      assert task["dependencies"] == []
      assert task["dependents"] == ["app#build"]
      assert task["cache"] == %{"status" => "MISS"}
    end

    test "forces stream log order so a running task's output is never silent" do
      # Turbo's own --log-order=auto resolves to "grouped" off a TTY (every
      # dxcore agent run), holding a task's whole output until it ends. A
      # hung dependency then prints nothing for the task's entire runtime
      # (#11867, #11876). --log-order=stream makes each line reach the
      # agent's log as turbo prints it, still prefixed with <package>:<task>.
      json =
        ~s({"tasks":[{"taskId":"app#e2e","task":"e2e","package":"app","hash":"abc","dependencies":[]}]})

      assert {:ok, [task]} = Turbo.parse_graph(json)
      assert task["command"] == "npx turbo run e2e --filter=app --log-order=stream"
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

    test "a dropped task passes its own edges on, through chains of dropped tasks" do
      # shell#test:part-1 -> shell#test:binary (no script) -> shell#build. The
      # part must still wait on #build, and a failed #build must still skip the
      # part, or every part compiles #build itself in parallel (#15603).
      # x#a -> x#gap1 -> x#gap2 -> x#b covers a chain of two dropped tasks.
      task = fn id, command, deps, dependents ->
        [package, name] = String.split(id, "#")

        %{
          "taskId" => id,
          "task" => name,
          "package" => package,
          "hash" => id,
          "command" => command,
          "dependencies" => deps,
          "dependents" => dependents
        }
      end

      json =
        Jason.encode!(%{
          "tasks" => [
            task.("shell#build", "mix compile", [], ["shell#test:binary"]),
            task.("shell#test:binary", "<NONEXISTENT>", ["shell#build"], [
              "shell#test:part-1",
              "shell#test:part-2"
            ]),
            task.("shell#test:part-1", "mix test", ["shell#test:binary", "lib#build"], []),
            task.("shell#test:part-2", "mix test", ["shell#test:binary"], []),
            task.("lib#build", "tsup", [], ["shell#test:part-1"]),
            task.("x#b", "make", [], ["x#gap2"]),
            task.("x#gap2", "<NONEXISTENT>", ["x#b"], ["x#gap1"]),
            task.("x#gap1", "<NONEXISTENT>", ["x#gap2"], ["x#a"]),
            task.("x#a", "make", ["x#gap1"], [])
          ]
        })

      assert {:ok, tasks} = Turbo.parse_graph(json)
      by_id = Map.new(tasks, &{&1["taskId"], &1})

      assert Enum.sort(Map.keys(by_id)) ==
               [
                 "lib#build",
                 "shell#build",
                 "shell#test:part-1",
                 "shell#test:part-2",
                 "x#a",
                 "x#b"
               ]

      assert Enum.sort(by_id["shell#test:part-1"]["dependencies"]) == ["lib#build", "shell#build"]
      assert by_id["shell#test:part-2"]["dependencies"] == ["shell#build"]

      assert Enum.sort(by_id["shell#build"]["dependents"]) ==
               ["shell#test:part-1", "shell#test:part-2"]

      assert by_id["lib#build"]["dependents"] == ["shell#test:part-1"]
      assert by_id["x#a"]["dependencies"] == ["x#b"]
      assert by_id["x#b"]["dependents"] == ["x#a"]
    end

    test "a cycle among dropped tasks ends instead of looping" do
      json =
        Jason.encode!(%{
          "tasks" => [
            %{
              "taskId" => "p#a",
              "task" => "a",
              "package" => "p",
              "hash" => "1",
              "command" => "make",
              "dependencies" => ["p#n1"],
              "dependents" => []
            },
            %{
              "taskId" => "p#n1",
              "task" => "n1",
              "package" => "p",
              "hash" => "2",
              "command" => "<NONEXISTENT>",
              "dependencies" => ["p#n2"],
              "dependents" => ["p#a"]
            },
            %{
              "taskId" => "p#n2",
              "task" => "n2",
              "package" => "p",
              "hash" => "3",
              "command" => "<NONEXISTENT>",
              "dependencies" => ["p#n1"],
              "dependents" => ["p#n1"]
            }
          ]
        })

      assert {:ok, [a]} = Turbo.parse_graph(json)
      assert a["dependencies"] == []
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
