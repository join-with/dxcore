defmodule DxCore.Agents.CLI.DispatcherTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias DxCore.Agents.CLI.Dispatcher

  describe "parse_args/1" do
    test "extracts required flags" do
      args = [
        "--coordinator",
        "http://localhost:4000",
        "--session-id",
        "sess-123",
        "--token",
        "tok-abc"
      ]

      opts = Dispatcher.parse_args(args)

      assert Keyword.fetch!(opts, :coordinator) == "http://localhost:4000"
      assert Keyword.fetch!(opts, :session_id) == "sess-123"
      assert Keyword.fetch!(opts, :token) == "tok-abc"
    end

    test "extracts short aliases" do
      args = ["-c", "http://localhost:4000", "-s", "sess-456", "-t", "tok-def"]

      opts = Dispatcher.parse_args(args)

      assert Keyword.fetch!(opts, :coordinator) == "http://localhost:4000"
      assert Keyword.fetch!(opts, :session_id) == "sess-456"
      assert Keyword.fetch!(opts, :token) == "tok-def"
    end

    test "parses --timeout flag as integer" do
      args = ["-c", "http://localhost:4000", "-s", "s1", "-t", "t1", "--timeout", "1800"]

      opts = Dispatcher.parse_args(args)
      assert Keyword.fetch!(opts, :timeout) == 1800
    end

    test "-T short alias for --timeout" do
      args = ["-c", "http://localhost:4000", "-s", "s1", "-t", "t1", "-T", "600"]

      opts = Dispatcher.parse_args(args)
      assert Keyword.fetch!(opts, :timeout) == 600
    end

    test "timeout defaults to nil when not provided" do
      args = ["-c", "http://localhost:4000", "-s", "s1", "-t", "t1"]

      opts = Dispatcher.parse_args(args)
      assert Keyword.get(opts, :timeout) == nil
    end

    test "parses --build-system flag" do
      args = ["-c", "http://localhost:4000", "-s", "s1", "-t", "t1", "--build-system", "nx"]

      opts = Dispatcher.parse_args(args)
      assert Keyword.fetch!(opts, :build_system) == "nx"
    end

    test "-b short alias for --build-system" do
      args = ["-c", "http://localhost:4000", "-s", "s1", "-t", "t1", "-b", "turbo"]

      opts = Dispatcher.parse_args(args)
      assert Keyword.fetch!(opts, :build_system) == "turbo"
    end
  end

  describe "parse_args --failure-strategy" do
    test "parses --failure-strategy flag" do
      args = [
        "--coordinator",
        "http://localhost:4000",
        "--session-id",
        "s1",
        "--token",
        "t1",
        "--failure-strategy",
        "fail-fast"
      ]

      opts = Dispatcher.parse_args(args)
      assert opts[:failure_strategy] == "fail-fast"
    end

    test "defaults to nil when not provided" do
      args = ["--coordinator", "http://localhost:4000", "--session-id", "s1", "--token", "t1"]
      opts = Dispatcher.parse_args(args)
      assert opts[:failure_strategy] == nil
    end
  end

  describe "format_summary/1" do
    test "formats successful run summary" do
      summary = %{
        "status" => "complete",
        "tasks" => [
          %{
            "task_id" => "pkg#lint",
            "package" => "pkg",
            "task" => "lint",
            "status" => "done",
            "cached" => false,
            "agent_id" => "agent-1",
            "duration_ms" => 1200,
            "exit_code" => 0
          },
          %{
            "task_id" => "pkg#build",
            "package" => "pkg",
            "task" => "build",
            "status" => "done",
            "cached" => true,
            "agent_id" => nil,
            "duration_ms" => nil,
            "exit_code" => nil
          }
        ],
        "counts" => %{"passed" => 1, "failed" => 0, "skipped" => 0, "cached" => 1},
        "failures" => []
      }

      output = Dispatcher.format_summary(summary)
      assert output =~ "Run Summary"
      assert output =~ "pkg#lint"
      assert output =~ "agent-1"
      assert output =~ "OK"
      assert output =~ "CACHED"
      assert output =~ "1 passed, 0 failed, 0 skipped, 1 cached"
    end

    test "aligns columns dynamically with varying task ID lengths" do
      summary = %{
        "status" => "complete",
        "tasks" => [
          %{
            "task_id" => "@repo/dxcore-coordinator-saas-e2e#build",
            "package" => "@repo/dxcore-coordinator-saas-e2e",
            "task" => "build",
            "status" => "done",
            "cached" => false,
            "agent_id" => "agent-3",
            "duration_ms" => 123_800,
            "exit_code" => 0
          },
          %{
            "task_id" => "@repo/infra-dxcore#lint",
            "package" => "@repo/infra-dxcore",
            "task" => "lint",
            "status" => "done",
            "cached" => false,
            "agent_id" => "agent-1",
            "duration_ms" => 2_600,
            "exit_code" => 0
          }
        ],
        "counts" => %{"passed" => 2, "failed" => 0, "skipped" => 0, "cached" => 0},
        "failures" => []
      }

      output = Dispatcher.format_summary(summary)
      lines = output |> String.split("\n") |> Enum.filter(&(&1 =~ ~r/@repo/))

      # Both agent columns should start at the same position
      positions = Enum.map(lines, fn line -> :binary.match(line, "agent-") |> elem(0) end)
      assert length(Enum.uniq(positions)) == 1

      # Both status columns should start at the same position
      ok_positions = Enum.map(lines, fn line -> :binary.match(line, "OK") |> elem(0) end)
      assert length(Enum.uniq(ok_positions)) == 1

      # Duration column should be right-aligned (all values end at the same position)
      end_positions = Enum.map(lines, &String.length(String.trim_trailing(&1)))
      assert length(Enum.uniq(end_positions)) == 1
    end

    test "formats failed run with failure details" do
      summary = %{
        "status" => "failed",
        "tasks" => [
          %{
            "task_id" => "pkg#lint",
            "package" => "pkg",
            "task" => "lint",
            "status" => "failed",
            "cached" => false,
            "agent_id" => "agent-1",
            "duration_ms" => 500,
            "exit_code" => 1
          },
          %{
            "task_id" => "pkg#build",
            "package" => "pkg",
            "task" => "build",
            "status" => "skipped",
            "cached" => false,
            "agent_id" => nil,
            "duration_ms" => nil,
            "exit_code" => nil
          }
        ],
        "counts" => %{"passed" => 0, "failed" => 1, "skipped" => 1, "cached" => 0},
        "failures" => [
          %{
            "task_id" => "pkg#lint",
            "agent_id" => "agent-1",
            "duration_ms" => 500,
            "exit_code" => 1,
            "output" => "Error: lint failed\nline 42: unused variable"
          }
        ]
      }

      output = Dispatcher.format_summary(summary)
      assert output =~ "FAIL(1)"
      assert output =~ "SKIPPED"
      assert output =~ "Failure Details"
      assert output =~ "lint failed"
    end
  end

  describe "read_stdin/2" do
    test "parses turbo JSON from stdin content" do
      json =
        ~s({"tasks":[{"taskId":"ui#build","task":"build","package":"ui","hash":"abc","command":"vite build","outputs":[],"dependencies":[],"dependents":[],"cache":{"status":"MISS"}}]})

      assert {:ok, [task]} = Dispatcher.read_stdin(json, "turbo")
      assert task["taskId"] == "ui#build"
    end

    test "parses nx JSON from stdin content" do
      json = File.read!(Path.join(File.cwd!(), "test/fixtures/nx_graph.json"))

      assert {:ok, tasks} = Dispatcher.read_stdin(json, "nx")
      assert length(tasks) == 3
    end

    test "returns error for empty input" do
      assert {:error, msg} = Dispatcher.read_stdin("", "turbo")
      assert msg =~ "No task graph provided"
    end

    test "returns error for whitespace-only input" do
      assert {:error, msg} = Dispatcher.read_stdin("  \n  ", "turbo")
      assert msg =~ "No task graph provided"
    end

    test "returns error for unknown build system" do
      assert {:error, msg} = Dispatcher.read_stdin("{}", "bazel")
      assert msg =~ "Unknown build system"
    end

    test "returns error for invalid JSON" do
      assert {:error, _msg} = Dispatcher.read_stdin("not json", "turbo")
    end

    test "returns error for :eof atom (no piped input)" do
      assert {:error, msg} = Dispatcher.read_stdin(:eof, "turbo")
      assert msg =~ "No task graph provided"
    end
  end

  describe "GenServer callbacks" do
    defp base_state(overrides \\ %{}) do
      struct!(
        DxCore.Agents.CLI.Dispatcher,
        Map.merge(
          %{
            client: self(),
            ws_monitor: make_ref(),
            session_id: "s1",
            run_id: "r1",
            timeout_ms: 60_000,
            tasks: nil,
            connected_agents: 0,
            managed: false,
            result_file: nil,
            read_run: fn _, _, _ -> {:error, :unused} end
          },
          overrides
        )
      )
    end

    test "run_complete with success stops normally" do
      state = base_state()

      msg =
        {:channel_message, "dispatcher:s1", "run_complete",
         %{"run_id" => "r1", "status" => "complete"}}

      assert {:stop, :normal, ^state} = Dispatcher.handle_info(msg, state)
    end

    test "run_complete with failure stops with shutdown failed" do
      state = base_state()

      msg =
        {:channel_message, "dispatcher:s1", "run_complete",
         %{"run_id" => "r1", "status" => "failed"}}

      assert {:stop, {:shutdown, :failed}, ^state} = Dispatcher.handle_info(msg, state)
    end

    test "timeout stops with shutdown timeout" do
      state = base_state()
      assert {:stop, {:shutdown, :timeout}, ^state} = Dispatcher.handle_info(:timeout, state)
    end

    test "task_started records the task as running" do
      state = base_state()

      msg =
        {:channel_message, "dispatcher:s1", "task_started",
         %{"task_id" => "t1", "agent_id" => "a1"}}

      assert {:noreply, new_state, 60_000} = Dispatcher.handle_info(msg, state)
      assert new_state.running == MapSet.new(["t1"])
    end

    test "task_completed records the task and returns noreply with timeout" do
      state = base_state()

      msg =
        {:channel_message, "dispatcher:s1", "task_completed",
         %{"task_id" => "t1", "exit_code" => 0, "duration_ms" => 100}}

      assert {:noreply, new_state, 60_000} = Dispatcher.handle_info(msg, state)
      assert new_state.finished == MapSet.new(["t1"])
    end

    test "joined with tasks asks every later rejoin to resume the run" do
      test_pid = self()

      client =
        spawn_link(fn ->
          receive do
            {:"$gen_call", from, {:push_and_wait, "submit_graph", _}} ->
              GenServer.reply(from, {:ok, %{"total_tasks" => 1, "cached_tasks" => 0}})
          end

          receive do
            {:"$gen_cast", msg} -> send(test_pid, {:ws_cast, msg})
          end
        end)

      state = base_state(%{client: client, tasks: [%{"taskId" => "t1"}]})
      assert {:noreply, _, 60_000} = Dispatcher.handle_info({:joined, "dispatcher:s1"}, state)
      assert_receive {:ws_cast, {:set_join_params, %{"resume" => true}}}
    end

    test "a failed submit does not ask to resume" do
      client =
        spawn_link(fn ->
          receive do
            {:"$gen_call", from, {:push_and_wait, "submit_graph", _}} ->
              GenServer.reply(from, {:error, :timeout})
          end

          receive do
            {:"$gen_cast", msg} -> flunk("unexpected cast #{inspect(msg)}")
          after
            100 -> :ok
          end
        end)

      state = base_state(%{client: client, tasks: [%{"taskId" => "t1"}]})

      assert {:stop, {:shutdown, :submit_failed}, _} =
               Dispatcher.handle_info({:joined, "dispatcher:s1"}, state)
    end

    test "task_failed returns noreply with timeout" do
      state = base_state()

      msg =
        {:channel_message, "dispatcher:s1", "task_failed",
         %{"task_id" => "t1", "reason" => "crash"}}

      assert {:noreply, ^state, 60_000} = Dispatcher.handle_info(msg, state)
    end

    test "task_log returns noreply with timeout" do
      state = base_state()

      msg =
        {:channel_message, "dispatcher:s1", "task_log", %{"agent_id" => "a1", "line" => "output"}}

      assert {:noreply, ^state, 60_000} = Dispatcher.handle_info(msg, state)
    end

    test "agent_connected increments connected_agents and returns noreply with timeout" do
      state = base_state(%{connected_agents: 0})

      msg =
        {:channel_message, "dispatcher:s1", "agent_connected", %{"agent_id" => "a1"}}

      assert {:noreply, new_state, 60_000} = Dispatcher.handle_info(msg, state)
      assert new_state.connected_agents == 1
    end

    test "agent_disconnected decrements connected_agents and returns noreply with timeout" do
      state = base_state(%{connected_agents: 1})

      msg =
        {:channel_message, "dispatcher:s1", "agent_disconnected", %{"agent_id" => "a1"}}

      assert {:noreply, new_state, 60_000} = Dispatcher.handle_info(msg, state)
      assert new_state.connected_agents == 0
    end

    test "disconnected returns noreply with timeout" do
      state = base_state()
      msg = {:disconnected, :connection_reset}
      assert {:noreply, ^state, 60_000} = Dispatcher.handle_info(msg, state)
    end

    test "joined with tasks submits graph and clears tasks" do
      tasks = [%{"taskId" => "t1"}]

      test_pid = self()

      client =
        spawn_link(fn ->
          receive do
            {:"$gen_call", from, {:push_and_wait, _event, _payload} = msg} ->
              GenServer.reply(from, {:ok, %{"total_tasks" => 1, "cached_tasks" => 0}})
              send(test_pid, {:ws_call, msg})
          end
        end)

      state = base_state(%{client: client, tasks: tasks})
      msg = {:joined, "dispatcher:s1"}
      assert {:noreply, new_state, 60_000} = Dispatcher.handle_info(msg, state)
      assert new_state.tasks == nil

      assert_receive {:ws_call,
                      {:push_and_wait, "submit_graph",
                       %{
                         "run_id" => "r1",
                         "tasks" => [%{"taskId" => "t1", "requirements" => %{}}],
                         "shard_config" => %{}
                       }}}
    end

    test "joined with tasks submits only the fields the coordinator reads" do
      # A turbo --dry=json task, abridged: inputs, outputs, env vars and the
      # resolved definition are what made an 827-task graph 9 MB.
      turbo_task = %{
        "taskId" => "@repo/app#test",
        "task" => "test",
        "package" => "@repo/app",
        "hash" => "abc123",
        "command" => "npx turbo run test --filter=@repo/app",
        "dependencies" => ["@repo/app#build"],
        "dependents" => [],
        "cache" => %{"status" => "MISS", "local" => false, "remote" => false},
        "cacheable" => true,
        "shard" => %{"index" => 0, "count" => 2},
        "directory" => "apps/app",
        "inputs" => %{"lib/app.ex" => "f00d", "mix.exs" => "beef"},
        "outputs" => ["_build/**"],
        "environmentVariables" => %{"specified" => %{"env" => ["MIX_ENV="]}},
        "resolvedTaskDefinition" => %{"dependsOn" => ["^build"]},
        "logFile" => "apps/app/.turbo/turbo-test.log"
      }

      test_pid = self()

      client =
        spawn_link(fn ->
          receive do
            {:"$gen_call", from, {:push_and_wait, _event, _payload} = msg} ->
              GenServer.reply(from, {:ok, %{"total_tasks" => 1, "cached_tasks" => 0}})
              send(test_pid, {:ws_call, msg})
          end
        end)

      state = base_state(%{client: client, tasks: [turbo_task]})

      assert {:noreply, _state, 60_000} =
               Dispatcher.handle_info({:joined, "dispatcher:s1"}, state)

      assert_receive {:ws_call, {:push_and_wait, "submit_graph", %{"tasks" => [submitted]}}}

      assert submitted == %{
               "taskId" => "@repo/app#test",
               "task" => "test",
               "package" => "@repo/app",
               "hash" => "abc123",
               "command" => "npx turbo run test --filter=@repo/app",
               "dependencies" => ["@repo/app#build"],
               "dependents" => [],
               "cache" => %{"status" => "MISS", "local" => false, "remote" => false},
               "cacheable" => true,
               "shard" => %{"index" => 0, "count" => 2},
               "requirements" => %{}
             }
    end

    test "joined with tasks submits graph including shard_config" do
      tasks = [%{"taskId" => "t1"}]
      shard_config = %{"e2e-app#test" => 4}
      test_pid = self()

      client =
        spawn_link(fn ->
          receive do
            {:"$gen_call", from, {:push_and_wait, _event, _payload} = msg} ->
              GenServer.reply(from, {:ok, %{"total_tasks" => 1, "cached_tasks" => 0}})
              send(test_pid, {:ws_call, msg})
          end
        end)

      state = base_state(%{client: client, tasks: tasks, shard_config: shard_config})
      msg = {:joined, "dispatcher:s1"}
      assert {:noreply, new_state, 60_000} = Dispatcher.handle_info(msg, state)
      assert new_state.tasks == nil

      assert_receive {:ws_call,
                      {:push_and_wait, "submit_graph",
                       %{
                         "run_id" => "r1",
                         "tasks" => [%{"taskId" => "t1", "requirements" => %{}}],
                         "shard_config" => %{"e2e-app#test" => 4}
                       }}}
    end

    test "joined without tasks is a reconnect" do
      state = base_state()
      msg = {:joined, "dispatcher:s1"}
      assert {:noreply, ^state, 60_000} = Dispatcher.handle_info(msg, state)
    end

    test "topic_closed returns noreply with timeout" do
      state = base_state()
      msg = {:topic_closed, "dispatcher:s1", :left}
      assert {:noreply, ^state, 60_000} = Dispatcher.handle_info(msg, state)
    end

    test "topic_closed with session_finished and no verdict fails" do
      state = base_state()

      assert {:stop, {:shutdown, :session_finished}, ^state} =
               Dispatcher.handle_info(
                 {:topic_closed, "dispatcher:s1",
                  {:failed_to_join, %{"reason" => "session_finished"}}},
                 state
               )
    end

    test "agent_disconnected when last agent disconnects logs warning" do
      state = base_state(%{connected_agents: 1})

      msg =
        {:channel_message, "dispatcher:s1", "agent_disconnected", %{"agent_id" => "a1"}}

      output =
        capture_io(fn ->
          Dispatcher.handle_info(msg, state)
        end)

      assert output =~ "All agents disconnected"
    end

    test "agent_disconnected when other agents remain does not log warning" do
      state = base_state(%{connected_agents: 2})

      msg =
        {:channel_message, "dispatcher:s1", "agent_disconnected", %{"agent_id" => "a1"}}

      output =
        capture_io(fn ->
          Dispatcher.handle_info(msg, state)
        end)

      refute output =~ "All agents disconnected"
    end

    test "presence_diff returns noreply with timeout" do
      state = base_state()
      msg = {:channel_message, "dispatcher:s1", "presence_diff", %{}}
      assert {:noreply, ^state, 60_000} = Dispatcher.handle_info(msg, state)
    end

    test "DOWN from client with reconnect_timeout stops dispatcher with shutdown" do
      state = base_state()
      ref = state.ws_monitor
      client = state.client
      msg = {:DOWN, ref, :process, client, {:shutdown, :reconnect_timeout}}
      assert {:stop, {:shutdown, :reconnect_timeout}, ^state} = Dispatcher.handle_info(msg, state)
    end

    test "DOWN from client with unexpected reason stops dispatcher" do
      state = base_state()
      ref = state.ws_monitor
      client = state.client
      msg = {:DOWN, ref, :process, client, :killed}

      assert {:stop, {:shutdown, {:ws_client_down, :killed}}, ^state} =
               Dispatcher.handle_info(msg, state)
    end

    test "unknown message returns noreply with timeout" do
      state = base_state()
      assert {:noreply, ^state, 60_000} = Dispatcher.handle_info(:something_random, state)
    end
  end

  describe "resolve_requirements/1" do
    setup do
      # Create temporary package dirs with package.json files
      tmp_dir = Path.join(System.tmp_dir!(), "dxcore-test-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(tmp_dir, "apps/cli"))
      File.mkdir_p!(Path.join(tmp_dir, "apps/web"))
      File.mkdir_p!(Path.join(tmp_dir, "packages/lib"))

      # cli: has * default and per-task override
      File.write!(
        Path.join(tmp_dir, "apps/cli/package.json"),
        Jason.encode!(%{
          "name" => "@repo/cli",
          "dxcore" => %{
            "requirements" => %{
              "*" => %{"zig" => "true"},
              "release-dev" => %{"zig" => "true", "github-release" => "true"}
            }
          }
        })
      )

      # web: has docker requirement for all tasks
      File.write!(
        Path.join(tmp_dir, "apps/web/package.json"),
        Jason.encode!(%{
          "name" => "@repo/web",
          "dxcore" => %{
            "requirements" => %{
              "*" => %{"docker" => "true"}
            }
          }
        })
      )

      # lib: no dxcore config
      File.write!(
        Path.join(tmp_dir, "packages/lib/package.json"),
        Jason.encode!(%{
          "name" => "@repo/lib"
        })
      )

      on_exit(fn -> File.rm_rf!(tmp_dir) end)
      %{tmp_dir: tmp_dir}
    end

    test "resolves exact task name over * default", %{tmp_dir: tmp_dir} do
      tasks = [
        %{
          "taskId" => "cli#release-dev",
          "task" => "release-dev",
          "package" => "@repo/cli",
          "directory" => Path.join(tmp_dir, "apps/cli")
        }
      ]

      result = Dispatcher.resolve_requirements(tasks)
      assert hd(result)["requirements"] == %{"zig" => "true", "github-release" => "true"}
    end

    test "falls back to * when no exact task match", %{tmp_dir: tmp_dir} do
      tasks = [
        %{
          "taskId" => "cli#build",
          "task" => "build",
          "package" => "@repo/cli",
          "directory" => Path.join(tmp_dir, "apps/cli")
        }
      ]

      result = Dispatcher.resolve_requirements(tasks)
      assert hd(result)["requirements"] == %{"zig" => "true"}
    end

    test "defaults to empty map when no dxcore config", %{tmp_dir: tmp_dir} do
      tasks = [
        %{
          "taskId" => "lib#build",
          "task" => "build",
          "package" => "@repo/lib",
          "directory" => Path.join(tmp_dir, "packages/lib")
        }
      ]

      result = Dispatcher.resolve_requirements(tasks)
      assert hd(result)["requirements"] == %{}
    end

    test "handles missing package.json gracefully", %{tmp_dir: tmp_dir} do
      tasks = [
        %{
          "taskId" => "missing#build",
          "task" => "build",
          "package" => "@repo/missing",
          "directory" => Path.join(tmp_dir, "apps/missing")
        }
      ]

      result = Dispatcher.resolve_requirements(tasks)
      assert hd(result)["requirements"] == %{}
    end

    test "processes multiple tasks from different packages", %{tmp_dir: tmp_dir} do
      tasks = [
        %{
          "taskId" => "cli#build",
          "task" => "build",
          "package" => "@repo/cli",
          "directory" => Path.join(tmp_dir, "apps/cli")
        },
        %{
          "taskId" => "web#build",
          "task" => "build",
          "package" => "@repo/web",
          "directory" => Path.join(tmp_dir, "apps/web")
        },
        %{
          "taskId" => "lib#build",
          "task" => "build",
          "package" => "@repo/lib",
          "directory" => Path.join(tmp_dir, "packages/lib")
        }
      ]

      result = Dispatcher.resolve_requirements(tasks)
      requirements = Enum.map(result, & &1["requirements"])

      assert Enum.at(requirements, 0) == %{"zig" => "true"}
      assert Enum.at(requirements, 1) == %{"docker" => "true"}
      assert Enum.at(requirements, 2) == %{}
    end
  end

  describe "await_exit/1" do
    # Deterministically wait until `monitoring_pid` has a monitor on `monitored_pid`.
    # Uses Process.info/2 instead of timing-based sleeps to avoid race conditions.
    defp wait_for_monitor(monitored_pid, monitoring_pid) do
      case Process.info(monitored_pid, :monitored_by) do
        {:monitored_by, monitors} ->
          if monitoring_pid in monitors do
            :ok
          else
            Process.sleep(1)
            wait_for_monitor(monitored_pid, monitoring_pid)
          end

        nil ->
          raise "Process #{inspect(monitored_pid)} exited before monitor was established"
      end
    end

    test "returns :normal when process exits normally" do
      test_pid = self()
      pid = spawn(fn -> receive do: (:go -> :ok) end)

      task =
        Task.async(fn ->
          result = Dispatcher.await_exit(pid)
          send(test_pid, {:result, result})
          result
        end)

      wait_for_monitor(pid, task.pid)
      send(pid, :go)
      assert_receive {:result, :normal}, 5_000
    end

    test "returns exit reason when process exits abnormally" do
      test_pid = self()
      pid = spawn(fn -> receive do: (:go -> exit({:shutdown, :failed})) end)

      task =
        Task.async(fn ->
          result = Dispatcher.await_exit(pid)
          send(test_pid, {:result, result})
          result
        end)

      wait_for_monitor(pid, task.pid)
      send(pid, :go)
      assert_receive {:result, {:shutdown, :failed}}, 5_000
    end

    test "process is not linked to caller" do
      pid = spawn(fn -> Process.sleep(50) end)
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    end
  end

  describe "wire_fields/0" do
    # The coordinator lives in another package, so the field list can't be
    # shared code; this reads its parser and fails when the two drift apart.
    test "are exactly the task fields the coordinator's TaskGraph reads" do
      path =
        Path.expand(
          "../../../../../../packages/dxcore-core/lib/dx_core/core/task_graph.ex",
          __DIR__
        )

      source = File.read!(path)

      read_by_coordinator =
        Regex.scan(~r/raw\["([A-Za-z]+)"\]|defp parse_[a-z_]+\(%\{"([A-Za-z]+)"/, source)
        |> Enum.map(fn [_ | groups] -> Enum.find(groups, &(&1 != "")) end)
        |> Enum.uniq()

      assert length(read_by_coordinator) == 11
      assert Enum.sort(Dispatcher.wire_fields()) == Enum.sort(read_by_coordinator)
    end
  end

  describe "rejoining a run (#11951)" do
    defp rejoin_state(overrides \\ %{}) do
      struct!(
        Dispatcher,
        Map.merge(
          %{
            client: self(),
            ws_monitor: make_ref(),
            session_id: "s1",
            run_id: "r1",
            timeout_ms: 60_000,
            tasks: nil,
            read_run: fn _, _, _ -> {:error, :unused} end
          },
          overrides
        )
      )
    end

    defp snapshot(status, tasks, pending) do
      {:channel_message, "dispatcher:s1", "run_snapshot",
       %{
         "run_id" => "uuid-1",
         "status" => status,
         "pending" => pending,
         "summary" => %{
           "status" => status,
           "tasks" => tasks,
           "counts" => %{"passed" => 1, "failed" => 0, "skipped" => 0, "cached" => 1},
           "failures" => []
         }
       }}
    end

    defp task(id, status, extra \\ %{}),
      do: Map.merge(%{"task_id" => id, "status" => status, "cached" => false}, extra)

    defp completed(id, exit_code),
      do:
        {:channel_message, "dispatcher:s1", "task_completed",
         %{"task_id" => id, "exit_code" => exit_code, "duration_ms" => 5}}

    test "a running snapshot reports each finished task once and keeps waiting" do
      tasks = [
        task("a", "done"),
        task("b", "failed", %{"exit_code" => 2}),
        task("c", "running"),
        task("d", "done", %{"cached" => true})
      ]

      output =
        capture_io(fn ->
          {:noreply, state, 60_000} =
            Dispatcher.handle_info(snapshot("running", tasks, 1), rejoin_state())

          send(self(), {:state, state})
        end)

      assert_received {:state, state}
      assert state.finished == MapSet.new(["a", "b"])
      assert output =~ "Task a OK (replayed)"
      assert output =~ "Task b FAIL(2) (replayed)"
      refute output =~ "Task c"
      refute output =~ "Task d"
      assert output =~ "2 tasks finished, 1 pending (running)"
    end

    test "a task already reported live is not reported again by the snapshot, nor the reverse" do
      output =
        capture_io(fn ->
          {:noreply, s1, _} = Dispatcher.handle_info(completed("a", 0), rejoin_state())

          {:noreply, s2, _} =
            Dispatcher.handle_info(
              snapshot("running", [task("a", "done"), task("b", "done")], 0),
              s1
            )

          {:noreply, s3, _} = Dispatcher.handle_info(completed("b", 0), s2)
          send(self(), {:state, s3})
        end)

      assert_received {:state, state}
      assert state.finished == MapSet.new(["a", "b"])
      assert length(Regex.scan(~r/Task a /, output)) == 1
      assert length(Regex.scan(~r/Task b /, output)) == 1
    end

    test "a snapshot of a finished run keeps waiting for the run_complete behind it" do
      capture_io(fn ->
        for status <- ["complete", "failed", "cancelled"] do
          assert {:noreply, _, 60_000} =
                   Dispatcher.handle_info(
                     snapshot(status, [task("a", "done")], 0),
                     rejoin_state()
                   )
        end
      end)
    end

    test "a malformed snapshot is ignored" do
      state = rejoin_state()

      capture_io(fn ->
        for payload <- [
              %{},
              %{"status" => "running"},
              %{"status" => "running", "summary" => %{"tasks" => [%{"task_id" => 1}]}},
              "nope"
            ] do
          msg = {:channel_message, "dispatcher:s1", "run_snapshot", payload}
          assert {:noreply, ^state, 60_000} = Dispatcher.handle_info(msg, state)
        end
      end)
    end

    test "a refused resume stops the dispatch as a failure" do
      for reason <- ["run_not_found", "invalid_join_params"] do
        msg = {:topic_closed, "dispatcher:s1", {:failed_to_join, %{"reason" => reason}}}

        capture_io(fn ->
          assert {:stop, {:shutdown, :resume_refused}, _} =
                   Dispatcher.handle_info(msg, rejoin_state())
        end)
      end
    end
  end

  describe "a run the coordinator owns (#15513)" do
    # A WsClient stand-in. It answers every push_and_wait with `reply` and
    # tells the test which event and payload were pushed.
    defp answering_client(reply) do
      test_pid = self()
      spawn_link(fn -> answer_loop(test_pid, reply) end)
    end

    defp answer_loop(test_pid, reply) do
      receive do
        {:"$gen_call", from, {:push_and_wait, event, payload}} ->
          send(test_pid, {:pushed, event, payload})
          GenServer.reply(from, if(is_function(reply), do: reply.(event, payload), else: reply))

        {:"$gen_cast", msg} ->
          send(test_pid, {:ws_cast, msg})
      end

      answer_loop(test_pid, reply)
    end

    defp completed_msg(id, exit_code),
      do:
        {:channel_message, "dispatcher:s1", "task_completed",
         %{"task_id" => id, "exit_code" => exit_code, "duration_ms" => 5}}

    defp lines(output), do: String.split(output, "\n", trim: true)

    @passed %{
      "result" => "passed",
      "total" => 4,
      "cached" => 0,
      "left" => 0,
      "failed" => 0,
      "failed_tasks" => []
    }

    defp complete(result, status \\ "complete"),
      do:
        {:channel_message, "t", "run_complete",
         %{"run_id" => "r", "status" => status, "result" => result}}

    test "submits deadline_at and hard_stop_at and keeps no timer" do
      deadline = ~U[2099-11-11 10:12:00Z]
      me = self()

      client =
        answering_client(fn "submit_graph", payload ->
          send(me, {:submitted, payload})

          {:ok,
           %{
             "run_id" => "r",
             "total_tasks" => 4,
             "cached_tasks" => 0,
             "deadline_at" => "2099-11-11T10:12:00Z",
             "hard_stop_at" => "2099-11-11T10:14:00Z"
           }}
        end)

      state =
        base_state(%{
          client: client,
          tasks: [%{"taskId" => "a#build"}],
          managed: true,
          deadline: deadline,
          hard_stop_after_ms: 120_000,
          timeout_ms: :infinity
        })

      capture_io(fn ->
        assert {:noreply, _state, :infinity} = Dispatcher.handle_info({:joined, "t"}, state)
      end)

      assert_received {:submitted,
                       %{
                         "deadline_at" => "2099-11-11T10:12:00Z",
                         "hard_stop_at" => "2099-11-11T10:14:00Z"
                       }}

      refute_receive :deadline, 50
      refute_receive :hard_stop, 0
    end

    test "a run with no deadline sends none and keeps the idle timeout" do
      me = self()

      client =
        answering_client(fn "submit_graph", payload ->
          send(me, {:submitted, payload})
          {:ok, %{"run_id" => "r", "total_tasks" => 4, "cached_tasks" => 0}}
        end)

      state = base_state(%{client: client, tasks: [%{"taskId" => "a#build"}]})

      capture_io(fn ->
        assert {:noreply, _, 60_000} = Dispatcher.handle_info({:joined, "t"}, state)
      end)

      assert_received {:submitted, payload}
      refute Map.has_key?(payload, "deadline_at")
      refute Map.has_key?(payload, "hard_stop_at")
      refute_receive :deadline, 50
    end

    test "a coordinator that drops the deadline is refused" do
      client =
        answering_client(fn
          "submit_graph", _ -> {:ok, %{"run_id" => "r", "total_tasks" => 4, "cached_tasks" => 0}}
          "cancel_run", _ -> {:ok, %{"cancelled" => true}}
        end)

      state =
        base_state(%{
          client: client,
          tasks: [%{"taskId" => "a#build"}],
          managed: true,
          deadline: ~U[2099-11-11 10:12:00Z],
          hard_stop_after_ms: 120_000
        })

      capture_io(fn ->
        assert {:stop, {:shutdown, :deadline_unsupported}, _} =
                 Dispatcher.handle_info({:joined, "t"}, state)
      end)

      assert_received {:pushed, "cancel_run", %{"run_id" => "r"}}
    end

    @tag :tmp_dir
    test "a dispatch that starts at its deadline submits nothing and is unfinished", %{
      tmp_dir: dir
    } do
      path = Path.join(dir, "r.json")

      for deadline <- [~U[2020-01-01 00:00:00Z], DateTime.add(DateTime.utc_now(), 2, :second)] do
        state =
          base_state(%{
            client: answering_client(fn _, _ -> flunk("nothing is submitted") end),
            tasks: [%{"taskId" => "a#build"}, %{"taskId" => "b#build"}, %{"taskId" => "c#build"}],
            managed: true,
            deadline: deadline,
            result_file: path
          })

        output =
          capture_io(fn ->
            assert {:stop, {:shutdown, :unfinished}, _} =
                     Dispatcher.handle_info({:joined, "t"}, state)
          end)

        assert output =~ "Unfinished at the deadline: 3 of 3 tasks left"
        refute_received {:pushed, _, _}

        assert Jason.decode!(File.read!(path)) == %{
                 "result" => "unfinished",
                 "total" => 3,
                 "cached" => 0,
                 "left" => 3,
                 "failed" => 0,
                 "failed_tasks" => []
               }
      end
    end

    @tag :tmp_dir
    test "a run with no deadline treats an unfinished verdict as a failure, quietly", %{
      tmp_dir: dir
    } do
      path = Path.join(dir, "r.json")
      unfinished = %{@passed | "result" => "unfinished", "left" => 2}

      output =
        capture_io(fn ->
          assert {:stop, {:shutdown, :failed}, _} =
                   Dispatcher.handle_info(
                     complete(unfinished, "cancelled"),
                     base_state(%{result_file: path})
                   )
        end)

      refute output =~ "Unfinished at the deadline"
      assert Jason.decode!(File.read!(path)) == %{unfinished | "result" => "failed"}

      capture_io(fn ->
        assert {:stop, :normal, _} = Dispatcher.handle_info(complete(@passed), base_state(%{}))
      end)
    end

    @tag timeout: 30_000
    test "a coordinator that drops the deadline and never answers cancel_run still stops" do
      client =
        answering_client(fn "submit_graph", _ ->
          {:ok, %{"run_id" => "r", "total_tasks" => 4, "cached_tasks" => 0}}
        end)

      # Answers submit_graph, then goes silent on cancel_run.
      silent = spawn_link(fn -> silent_after_submit(client) end)

      state =
        base_state(%{
          client: silent,
          tasks: [%{"taskId" => "a#build"}],
          managed: true,
          deadline: ~U[2099-11-11 10:12:00Z],
          hard_stop_after_ms: 120_000
        })

      capture_io(fn ->
        assert {:stop, {:shutdown, :deadline_unsupported}, _} =
                 Dispatcher.handle_info({:joined, "t"}, state)
      end)
    end

    defp silent_after_submit(client) do
      receive do
        {:"$gen_call", from, {:push_and_wait, "submit_graph", _} = call} ->
          GenServer.reply(from, GenServer.call(client, call))
          silent_after_submit(client)

        {:"$gen_call", _from, _cancel} ->
          Process.sleep(:infinity)

        {:"$gen_cast", _} ->
          silent_after_submit(client)
      end
    end

    @tag :tmp_dir
    test "no run_complete: the backstop reads the verdict after the hard stop", %{tmp_dir: dir} do
      path = Path.join(dir, "r.json")
      failed = %{@passed | "result" => "failed", "failed" => 1, "failed_tasks" => ["a#t"]}

      client =
        answering_client(fn "submit_graph", _ ->
          {:ok,
           %{
             "run_id" => "r",
             "total_tasks" => 4,
             "cached_tasks" => 0,
             "deadline_at" => "x",
             "hard_stop_at" => "x"
           }}
        end)

      state =
        base_state(%{
          client: client,
          tasks: [%{"taskId" => "a#build"}],
          managed: true,
          deadline: DateTime.add(DateTime.utc_now(), 6, :second),
          hard_stop_after_ms: 0,
          verdict_grace_ms: 0,
          timeout_ms: :infinity,
          result_file: path,
          read_run: fn _, _, _ -> {:ok, %{"run" => %{"id" => "r", "result" => failed}}} end
        })

      capture_io(fn ->
        assert {:noreply, state, :infinity} = Dispatcher.handle_info({:joined, "t"}, state)
        assert_receive :read_verdict, 8_000

        assert {:stop, {:shutdown, :failed}, _} = Dispatcher.handle_info(:read_verdict, state)
      end)

      assert Jason.decode!(File.read!(path)) == failed
    end

    test "the backstop with no verdict keeps waiting and asks again" do
      state =
        base_state(%{
          managed: true,
          coordinator_run_id: "r",
          timeout_ms: :infinity,
          read_run: fn _, _, _ -> {:ok, %{"run" => %{"id" => "r", "result" => nil}}} end
        })

      assert {:noreply, _, :infinity} = Dispatcher.handle_info(:read_verdict, state)
    end

    test "a rejoin reads the run once; a verdict ends the dispatch" do
      state =
        base_state(%{
          managed: true,
          coordinator_run_id: "r",
          read_run: fn _, _, _ -> {:ok, %{"run" => %{"id" => "r", "result" => @passed}}} end
        })

      capture_io(fn ->
        assert {:stop, :normal, _} = Dispatcher.handle_info({:joined, "t"}, state)
      end)
    end

    test "a verdict for another run, or before the run has an id, is no result" do
      read = fn _, _, _ -> {:ok, %{"run" => %{"id" => "other", "result" => @passed}}} end

      assert {:noreply, _, 60_000} =
               Dispatcher.handle_info(
                 {:joined, "t"},
                 base_state(%{coordinator_run_id: "r", read_run: read})
               )

      msg = {:channel_message, "t", "run_complete", %{"status" => "complete"}}

      capture_io(fn ->
        assert {:stop, {:shutdown, :failed}, _} =
                 Dispatcher.handle_info(
                   msg,
                   base_state(%{
                     managed: true,
                     coordinator_run_id: nil,
                     read_run: fn _, _, _ ->
                       {:ok, %{"run" => %{"id" => nil, "result" => @passed}}}
                     end
                   })
                 )
      end)
    end

    @tag :tmp_dir
    test "a submit refused for a past deadline_at is unfinished, too-far and other refusals fail",
         %{
           tmp_dir: dir
         } do
      path = Path.join(dir, "r.json")

      past =
        answering_client(fn "submit_graph", _ ->
          {:error,
           %{
             "reason" => "invalid_deadline",
             "field" => "deadline_at",
             "message" => "is in the past"
           }}
        end)

      too_far =
        answering_client(fn "submit_graph", _ ->
          {:error,
           %{
             "reason" => "invalid_deadline",
             "field" => "deadline_at",
             "message" => "is more than 60 minutes ahead"
           }}
        end)

      other =
        answering_client(fn "submit_graph", _ ->
          {:error, %{"reason" => "invalid_deadline", "field" => "hard_stop_at", "message" => "m"}}
        end)

      base = %{
        tasks: [%{"taskId" => "a#build"}, %{"taskId" => "b#build"}],
        managed: true,
        deadline: ~U[2099-11-11 10:12:00Z],
        hard_stop_after_ms: 120_000,
        result_file: path
      }

      output =
        capture_io(fn ->
          assert {:stop, {:shutdown, :unfinished}, _} =
                   Dispatcher.handle_info(
                     {:joined, "t"},
                     base_state(Map.put(base, :client, past))
                   )
        end)

      assert output =~ "Unfinished at the deadline: 2 of 2 tasks left"
      assert Jason.decode!(File.read!(path))["result"] == "unfinished"

      for client <- [too_far, other] do
        capture_io(fn ->
          assert {:stop, {:shutdown, :submit_failed}, _} =
                   Dispatcher.handle_info(
                     {:joined, "t"},
                     base_state(Map.put(base, :client, client))
                   )
        end)
      end
    end

    @tag :tmp_dir
    test "exits on the verdict in run_complete and writes it", %{tmp_dir: dir} do
      path = Path.join(dir, "r.json")
      state = base_state(%{managed: true, result_file: path})

      capture_io(fn ->
        assert {:stop, :normal, _} = Dispatcher.handle_info(complete(@passed), state)
      end)

      assert Jason.decode!(File.read!(path)) == @passed

      unfinished = %{@passed | "result" => "unfinished", "left" => 3}

      output =
        capture_io(fn ->
          assert {:stop, {:shutdown, :unfinished}, _} =
                   Dispatcher.handle_info(complete(unfinished, "failed"), state)
        end)

      assert output =~ "Unfinished at the deadline: 3 of 4 tasks left"
      assert Jason.decode!(File.read!(path))["result"] == "unfinished"

      failed = %{@passed | "result" => "failed", "failed" => 1, "failed_tasks" => ["a#test"]}

      capture_io(fn ->
        assert {:stop, {:shutdown, :failed}, _} =
                 Dispatcher.handle_info(complete(failed, "failed"), state)
      end)
    end

    test "with no verdict in run_complete, a deadline run reads it from the coordinator" do
      me = self()

      read = fn url, token, sid ->
        send(me, {:read, url, token, sid})

        {:ok,
         %{
           "run" => %{
             "id" => "coord-r",
             "result" => %{@passed | "result" => "unfinished", "left" => 1}
           }
         }}
      end

      state =
        base_state(%{
          managed: true,
          read_run: read,
          coordinator_run_id: "coord-r",
          coordinator_url: "http://c",
          token: "tok"
        })

      msg =
        {:channel_message, "t", "run_complete", %{"run_id" => "coord-r", "status" => "failed"}}

      capture_io(fn ->
        assert {:stop, {:shutdown, :unfinished}, _} = Dispatcher.handle_info(msg, state)
      end)

      assert_received {:read, "http://c", "tok", "s1"}
    end

    test "a deadline run with no verdict anywhere fails, also for another run's verdict" do
      msg = {:channel_message, "t", "run_complete", %{"status" => "complete"}}
      other_run = {:ok, %{"run" => %{"id" => "other", "result" => @passed}}}

      for read <- [{:error, {:http, 404}}, other_run, {:ok, %{"run" => nil}}] do
        state =
          base_state(%{managed: true, coordinator_run_id: "r", read_run: fn _, _, _ -> read end})

        capture_io(fn ->
          assert {:stop, {:shutdown, :failed}, _} = Dispatcher.handle_info(msg, state)
        end)
      end
    end

    test "a legacy run_complete: complete passes, cancelled or failed fails" do
      state = base_state(%{})

      for {status, expected} <- [
            {"complete", :normal},
            {"cancelled", {:shutdown, :failed}},
            {"failed", {:shutdown, :failed}}
          ] do
        msg = {:channel_message, "t", "run_complete", %{"status" => status}}

        capture_io(fn ->
          assert {:stop, ^expected, _} = Dispatcher.handle_info(msg, state)
        end)
      end
    end

    test "a finished session on rejoin reads the verdict, else fails" do
      refused = {:topic_closed, "t", {:failed_to_join, %{"reason" => "session_finished"}}}

      with_verdict =
        base_state(%{
          managed: true,
          coordinator_run_id: "r",
          read_run: fn _, _, _ -> {:ok, %{"run" => %{"id" => "r", "result" => @passed}}} end
        })

      capture_io(fn ->
        assert {:stop, :normal, _} = Dispatcher.handle_info(refused, with_verdict)
      end)

      without = base_state(%{read_run: fn _, _, _ -> {:error, {:http, 404}} end})

      capture_io(fn ->
        assert {:stop, {:shutdown, :session_finished}, _} =
                 Dispatcher.handle_info(refused, without)
      end)
    end

    test "a refused resume reads the verdict too" do
      refused = {:topic_closed, "t", {:failed_to_join, %{"reason" => "run_not_found"}}}
      unfinished = %{@passed | "result" => "unfinished", "left" => 2}

      state =
        base_state(%{
          managed: true,
          coordinator_run_id: "r",
          read_run: fn _, _, _ -> {:ok, %{"run" => %{"id" => "r", "result" => unfinished}}} end
        })

      capture_io(fn ->
        assert {:stop, {:shutdown, :unfinished}, _} = Dispatcher.handle_info(refused, state)
      end)
    end

    test "a task_log line is still printed (the gate log keeps every task's output)" do
      out =
        capture_io(fn ->
          Dispatcher.handle_info(
            {:channel_message, "t", "task_log",
             %{"agent_id" => "ag", "line" => "vitest: 3 passed"}},
            base_state(%{})
          )
        end)

      assert out =~ "vitest: 3 passed"
    end

    test "a task with its own requirements and no directory keeps them" do
      [task] =
        Dispatcher.resolve_requirements([
          %{"taskId" => "a#e2e", "task" => "e2e", "requirements" => %{"docker" => true}}
        ])

      assert task["requirements"] == %{"docker" => true}
    end

    test "a replayed snapshot records the tasks still running" do
      snapshot =
        {:channel_message, "dispatcher:s1", "run_snapshot",
         %{
           "run_id" => "uuid-1",
           "status" => "running",
           "pending" => 1,
           "summary" => %{
             "tasks" => [
               %{"task_id" => "t1", "status" => "done", "cached" => false},
               %{"task_id" => "t2", "status" => "running", "cached" => false},
               %{"task_id" => "t3", "status" => "pending", "cached" => false}
             ]
           }
         }}

      assert {:noreply, new_state, 60_000} = Dispatcher.handle_info(snapshot, base_state())
      assert new_state.running == MapSet.new(["t2"])
      assert new_state.finished == MapSet.new(["t1"])
    end

    test "a task the snapshot shows queued again leaves the running set" do
      snapshot =
        {:channel_message, "dispatcher:s1", "run_snapshot",
         %{
           "run_id" => "uuid-1",
           "status" => "running",
           "pending" => 1,
           "summary" => %{
             "tasks" => [%{"task_id" => "t2", "status" => "pending", "cached" => false}]
           }
         }}

      state = base_state(%{running: MapSet.new(["t2"])})
      assert {:noreply, new_state, 60_000} = Dispatcher.handle_info(snapshot, state)
      assert new_state.running == MapSet.new()
    end

    test "await_exit_code/1 turns an unfinished stop into 75" do
      pid = spawn(fn -> receive do: (:go -> exit({:shutdown, :unfinished})) end)
      task = Task.async(fn -> Dispatcher.await_exit_code(pid) end)
      wait_for_monitor(pid, task.pid)
      send(pid, :go)
      assert Task.await(task) == 75
    end

    test "parse_args keeps --deadline and --hard-stop-after as strings" do
      opts =
        Dispatcher.parse_args(["--deadline", "2026-10-25T10:12:00Z", "--hard-stop-after", "30"])

      assert opts[:deadline] == "2026-10-25T10:12:00Z"
      assert opts[:hard_stop_after] == "30"
    end
  end
end
