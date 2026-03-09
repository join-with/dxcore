defmodule DxCore.Agents.CLI.DispatcherTest do
  use ExUnit.Case, async: true

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
            tasks: nil
          },
          overrides
        )
      )
    end

    test "run_complete with success stops normally" do
      state = base_state()

      msg =
        {:channel_message, "dispatcher:s1", "run_complete",
         %{"run_id" => "r1", "status" => "success"}}

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

    test "task_started returns noreply with timeout" do
      state = base_state()

      msg =
        {:channel_message, "dispatcher:s1", "task_started",
         %{"task_id" => "t1", "agent_id" => "a1"}}

      assert {:noreply, ^state, 60_000} = Dispatcher.handle_info(msg, state)
    end

    test "task_completed returns noreply with timeout" do
      state = base_state()

      msg =
        {:channel_message, "dispatcher:s1", "task_completed",
         %{"task_id" => "t1", "exit_code" => 0, "duration_ms" => 100}}

      assert {:noreply, ^state, 60_000} = Dispatcher.handle_info(msg, state)
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

    test "agent_connected returns noreply with timeout" do
      state = base_state()

      msg =
        {:channel_message, "dispatcher:s1", "agent_connected", %{"agent_id" => "a1"}}

      assert {:noreply, ^state, 60_000} = Dispatcher.handle_info(msg, state)
    end

    test "agent_disconnected returns noreply with timeout" do
      state = base_state()

      msg =
        {:channel_message, "dispatcher:s1", "agent_disconnected", %{"agent_id" => "a1"}}

      assert {:noreply, ^state, 60_000} = Dispatcher.handle_info(msg, state)
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
                       %{"run_id" => "r1", "tasks" => [%{"taskId" => "t1"}]}}}
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
end
