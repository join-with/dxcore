defmodule DxCore.Agents.CLI.AgentTest do
  use ExUnit.Case, async: true

  alias DxCore.Agents.CLI.Agent

  describe "parse_args/1" do
    test "extracts session_id and token flags" do
      args = [
        "--coordinator",
        "http://localhost:4000",
        "--agent-id",
        "a1",
        "--session-id",
        "sess-123",
        "--token",
        "tok-abc"
      ]

      {opts, _rest} = Agent.parse_args(args)

      assert Keyword.fetch!(opts, :session_id) == "sess-123"
      assert Keyword.fetch!(opts, :token) == "tok-abc"
    end

    test "extracts session_id and token via short aliases -s and -t" do
      args = [
        "-c",
        "http://localhost:4000",
        "-a",
        "a1",
        "-s",
        "sess-456",
        "-t",
        "tok-def"
      ]

      {opts, _rest} = Agent.parse_args(args)

      assert Keyword.fetch!(opts, :session_id) == "sess-456"
      assert Keyword.fetch!(opts, :token) == "tok-def"
    end

    test "extracts all existing flags alongside new ones" do
      args = [
        "--coordinator",
        "http://localhost:4000",
        "--agent-id",
        "agent-1",
        "--work-dir",
        "/tmp/work",
        "--session-id",
        "sess-789",
        "--token",
        "tok-ghi"
      ]

      {opts, _rest} = Agent.parse_args(args)

      assert Keyword.fetch!(opts, :coordinator) == "http://localhost:4000"
      assert Keyword.fetch!(opts, :agent_id) == "agent-1"
      assert Keyword.fetch!(opts, :work_dir) == "/tmp/work"
      assert Keyword.fetch!(opts, :session_id) == "sess-789"
      assert Keyword.fetch!(opts, :token) == "tok-ghi"
    end

    test "returns remaining non-option args in rest" do
      args = [
        "--coordinator",
        "http://localhost:4000",
        "--agent-id",
        "a1",
        "--session-id",
        "s1",
        "--token",
        "t1",
        "extra-arg"
      ]

      {_opts, rest} = Agent.parse_args(args)

      assert rest == ["extra-arg"]
    end

    test "parses --build-system flag" do
      args = [
        "--coordinator",
        "http://localhost:4000",
        "--agent-id",
        "a1",
        "--session-id",
        "s1",
        "--token",
        "t1",
        "--build-system",
        "nx"
      ]

      {opts, _rest} = Agent.parse_args(args)
      assert Keyword.fetch!(opts, :build_system) == "nx"
    end

    test "-b short alias for --build-system" do
      args = ["-c", "http://localhost:4000", "-a", "a1", "-s", "s1", "-t", "t1", "-b", "turbo"]
      {opts, _rest} = Agent.parse_args(args)
      assert Keyword.fetch!(opts, :build_system) == "turbo"
    end

    test "parses --tags flag" do
      args = [
        "--coordinator",
        "http://localhost:4000",
        "--agent-id",
        "a1",
        "--session-id",
        "s1",
        "--token",
        "t1",
        "--tags",
        "gpu=true,zone=us-east"
      ]

      {opts, _rest} = Agent.parse_args(args)
      assert Keyword.fetch!(opts, :tags) == "gpu=true,zone=us-east"
    end
  end

  describe "parse_tags/1" do
    test "parses comma-separated key=value pairs" do
      assert Agent.parse_tags("gpu=true,zone=us-east") == %{
               "gpu" => "true",
               "zone" => "us-east"
             }
    end

    test "handles key without value" do
      assert Agent.parse_tags("gpu") == %{"gpu" => "true"}
    end

    test "returns empty map for nil" do
      assert Agent.parse_tags(nil) == %{}
    end

    test "returns empty map for empty string" do
      assert Agent.parse_tags("") == %{}
    end

    test "trims whitespace in keys and values" do
      assert Agent.parse_tags(" gpu = true , zone = us-east ") == %{
               "gpu" => "true",
               "zone" => "us-east"
             }
    end
  end

  describe "detect_capabilities/1" do
    test "returns map with cpu_cores" do
      caps = Agent.detect_capabilities(nil)
      assert is_integer(caps["cpu_cores"])
      assert caps["cpu_cores"] > 0
      assert caps["tags"] == %{}
    end

    test "includes parsed tags when provided" do
      caps = Agent.detect_capabilities("gpu=true,zone=us-east")
      assert caps["tags"] == %{"gpu" => "true", "zone" => "us-east"}
    end

    test "memory_mb is an integer on Linux" do
      caps = Agent.detect_capabilities(nil)
      # On Linux /proc/meminfo should be available
      if File.exists?("/proc/meminfo") do
        assert is_integer(caps["memory_mb"])
        assert caps["memory_mb"] > 0
      else
        assert caps["memory_mb"] == nil
      end
    end
  end

  describe "GenServer callbacks" do
    defp base_state(overrides \\ %{}) do
      struct!(
        DxCore.Agents.CLI.Agent,
        Map.merge(
          %{
            client: self(),
            ws_monitor: make_ref(),
            agent_id: "a1",
            session_id: "s1",
            work_dir: ".",
            adapter: DxCore.Agents.BuildSystem.Turbo,
            current_port: nil,
            current_task_id: nil,
            start_time: nil,
            capabilities: %{
              "cpu_cores" => 4,
              "memory_mb" => 8192,
              "disk_free_mb" => nil,
              "tags" => %{}
            }
          },
          overrides
        )
      )
    end

    test "joined pushes agent_ready with capabilities" do
      state = base_state()
      msg = {:joined, "agent:s1"}
      assert {:noreply, ^state, 60_000} = Agent.handle_info(msg, state)

      assert_receive {:"$gen_cast",
                      {:push, "agent_ready",
                       %{"agent_id" => "a1", "capabilities" => capabilities}}}

      assert capabilities == state.capabilities
    end

    test "timeout when idle stops the GenServer" do
      state = base_state()
      assert {:stop, :normal, ^state} = Agent.handle_info(:timeout, state)
    end

    test "shutdown when idle stops without reporting task_result" do
      state = base_state()
      msg = {:channel_message, "agent:s1", "shutdown", %{"reason" => "run complete"}}
      assert {:stop, :normal, ^state} = Agent.handle_info(msg, state)
      refute_receive {:"$gen_cast", {:push, "task_result", _}}, 10
    end

    test "presence_diff is ignored with idle timeout" do
      state = base_state()
      msg = {:channel_message, "agent:s1", "presence_diff", %{}}
      assert {:noreply, ^state, 60_000} = Agent.handle_info(msg, state)
    end

    test "disconnected returns noreply with idle timeout" do
      state = base_state()
      msg = {:disconnected, :connection_reset}
      assert {:noreply, ^state, 60_000} = Agent.handle_info(msg, state)
    end

    test "topic_closed returns noreply with idle timeout" do
      state = base_state()
      msg = {:topic_closed, "agent:s1", :left}
      assert {:noreply, ^state, 60_000} = Agent.handle_info(msg, state)
    end

    test "DOWN from client with reconnect_timeout stops agent normally" do
      state = base_state()
      ref = state.ws_monitor
      client = state.client
      msg = {:DOWN, ref, :process, client, {:shutdown, :reconnect_timeout}}
      assert {:stop, :normal, ^state} = Agent.handle_info(msg, state)
    end

    test "DOWN from client with reconnect_timeout while busy stops without cleanup" do
      port = open_test_port()
      state = base_state(%{current_port: port, current_task_id: "t1", start_time: 0})
      ref = state.ws_monitor
      client = state.client
      msg = {:DOWN, ref, :process, client, {:shutdown, :reconnect_timeout}}
      assert {:stop, :normal, ^state} = Agent.handle_info(msg, state)
      refute_receive {:"$gen_cast", {:push, "task_result", _}}, 10
    end

    test "DOWN from client with unexpected reason stops agent" do
      state = base_state()
      ref = state.ws_monitor
      client = state.client
      msg = {:DOWN, ref, :process, client, :killed}

      assert {:stop, {:shutdown, {:ws_client_down, :killed}}, ^state} =
               Agent.handle_info(msg, state)
    end

    test "unknown message returns noreply with idle timeout" do
      state = base_state()
      assert {:noreply, ^state, 60_000} = Agent.handle_info(:something_random, state)
    end

    test "stale port data after exit_status is silently dropped" do
      port = Port.open({:spawn, "sleep 60"}, [:binary, :exit_status])

      on_exit(fn ->
        try do
          Port.close(port)
        catch
          :error, :badarg -> :ok
        end
      end)

      # State has no current_port (port already finished)
      state = base_state()
      msg = {port, {:data, {:eol, "stale output"}}}
      assert {:noreply, ^state, 60_000} = Agent.handle_info(msg, state)
      refute_receive {:"$gen_cast", {:push, "task_log", _}}, 10
    end

    defp open_test_port do
      port = Port.open({:spawn, "sleep 60"}, [:binary, :exit_status])

      on_exit(fn ->
        try do
          Port.close(port)
        catch
          :error, :badarg -> :ok
        end
      end)

      port
    end

    test "assign_task when idle opens port and transitions to busy" do
      state = base_state()

      msg =
        {:channel_message, "agent:s1", "assign_task",
         %{"task_id" => "t1", "package" => "web", "task" => "build"}}

      assert {:noreply, new_state, :infinity} = Agent.handle_info(msg, state)
      on_exit(fn -> catch_error(Port.close(new_state.current_port)) end)
      assert new_state.current_task_id == "t1"
      assert new_state.current_port != nil
      assert is_integer(new_state.start_time)
    end

    test "port eol data pushes task_log" do
      port = open_test_port()
      state = base_state(%{current_port: port, current_task_id: "t1", start_time: 0})

      msg = {port, {:data, {:eol, "test output"}}}
      assert {:noreply, ^state, :infinity} = Agent.handle_info(msg, state)

      assert_receive {:"$gen_cast",
                      {:push, "task_log", %{"task_id" => "t1", "line" => "test output"}}}
    end

    test "port noeol data pushes task_log" do
      port = open_test_port()
      state = base_state(%{current_port: port, current_task_id: "t1", start_time: 0})

      msg = {port, {:data, {:noeol, "partial"}}}
      assert {:noreply, ^state, :infinity} = Agent.handle_info(msg, state)

      assert_receive {:"$gen_cast",
                      {:push, "task_log", %{"task_id" => "t1", "line" => "partial"}}}
    end

    test "port exit_status pushes task_result and clears port from state" do
      port = open_test_port()
      start_time = System.monotonic_time(:millisecond)
      state = base_state(%{current_port: port, current_task_id: "t1", start_time: start_time})

      msg = {port, {:exit_status, 0}}
      assert {:noreply, new_state, 60_000} = Agent.handle_info(msg, state)
      assert new_state.current_port == nil
      assert new_state.current_task_id == nil
      assert new_state.start_time == nil

      assert_receive {:"$gen_cast", {:push, "task_result", payload}}
      assert payload["task_id"] == "t1"
      assert payload["exit_code"] == 0
      assert is_integer(payload["duration_ms"])
    end

    test "port exit_status with non-zero code reports correct exit_code" do
      port = open_test_port()

      state =
        base_state(%{
          current_port: port,
          current_task_id: "t1",
          start_time: System.monotonic_time(:millisecond)
        })

      msg = {port, {:exit_status, 1}}
      assert {:noreply, _new_state, 60_000} = Agent.handle_info(msg, state)

      assert_receive {:"$gen_cast", {:push, "task_result", payload}}
      assert payload["exit_code"] == 1
    end

    test "shutdown with active port closes port and reports interrupted" do
      port = open_test_port()

      state =
        base_state(%{
          current_port: port,
          current_task_id: "t1",
          start_time: System.monotonic_time(:millisecond)
        })

      msg = {:channel_message, "agent:s1", "shutdown", %{"reason" => "run complete"}}
      assert {:stop, :normal, _state} = Agent.handle_info(msg, state)

      assert_receive {:"$gen_cast", {:push, "task_result", payload}}
      assert payload["task_id"] == "t1"
      assert payload["exit_code"] == -1
      assert is_integer(payload["duration_ms"])
    end

    test "assign_task with active port logs warning and ignores" do
      port = open_test_port()
      state = base_state(%{current_port: port, current_task_id: "t1", start_time: 0})

      msg =
        {:channel_message, "agent:s1", "assign_task",
         %{"task_id" => "t2", "package" => "pkg", "task" => "build"}}

      assert {:noreply, ^state, :infinity} = Agent.handle_info(msg, state)
    end
  end

  describe "adapter pluggability" do
    defmodule FakeAdapter do
      @behaviour DxCore.Agents.BuildSystem

      @impl true
      def parse_graph(_json), do: {:ok, []}

      @impl true
      def task_command(_work_dir, _package, _task) do
        echo = System.find_executable("echo")
        {echo, ["fake-adapter-output"]}
      end
    end

    defmodule RaisingAdapter do
      @behaviour DxCore.Agents.BuildSystem

      @impl true
      def parse_graph(_json), do: {:ok, []}

      @impl true
      def task_command(_work_dir, _package, _task), do: raise("npx not found in PATH")
    end

    test "assign_task rescue reports exit_code -1 when adapter raises" do
      state = base_state(%{adapter: RaisingAdapter})

      msg =
        {:channel_message, "agent:s1", "assign_task",
         %{"task_id" => "t1", "package" => "web", "task" => "build"}}

      assert {:noreply, new_state, 60_000} = Agent.handle_info(msg, state)
      assert new_state.current_port == nil
      assert new_state.current_task_id == nil

      assert_receive {:"$gen_cast",
                      {:push, "task_result",
                       %{"task_id" => "t1", "exit_code" => -1, "duration_ms" => 0}}}
    end

    test "assign_task uses the adapter from state, not a hardcoded module" do
      state = base_state(%{adapter: FakeAdapter})

      msg =
        {:channel_message, "agent:s1", "assign_task",
         %{"task_id" => "t1", "package" => "web", "task" => "build"}}

      assert {:noreply, new_state, :infinity} = Agent.handle_info(msg, state)
      on_exit(fn -> catch_error(Port.close(new_state.current_port)) end)
      assert new_state.current_port != nil

      # The port should emit "fake-adapter-output" from echo
      assert_receive {_port, {:data, {:eol, "fake-adapter-output"}}}, 1000
    end
  end

  describe "shard-aware execution" do
    defmodule EnvPrinterAdapter do
      @behaviour DxCore.Agents.BuildSystem

      @impl true
      def parse_graph(_json), do: {:ok, []}

      @impl true
      def task_command(_work_dir, _package, _task) do
        sh = System.find_executable("sh")
        {sh, ["-c", "env | grep DXCORE || true"]}
      end
    end

    test "assign_task with shard sets DXCORE_SHARD_INDEX and DXCORE_SHARD_COUNT env vars" do
      state = base_state(%{adapter: EnvPrinterAdapter})

      msg =
        {:channel_message, "agent:s1", "assign_task",
         %{
           "task_id" => "t1",
           "package" => "web",
           "task" => "test",
           "shard" => %{"index" => 1, "count" => 2}
         }}

      assert {:noreply, new_state, :infinity} = Agent.handle_info(msg, state)
      on_exit(fn -> catch_error(Port.close(new_state.current_port)) end)
      assert new_state.current_task_id == "t1"

      # Collect all output lines from the port
      lines = collect_port_output(new_state.current_port)

      assert Enum.any?(lines, &String.contains?(&1, "DXCORE_SHARD_INDEX=1"))
      assert Enum.any?(lines, &String.contains?(&1, "DXCORE_SHARD_COUNT=2"))
    end

    test "assign_task without shard does not set DXCORE_SHARD env vars" do
      state = base_state(%{adapter: EnvPrinterAdapter})

      msg =
        {:channel_message, "agent:s1", "assign_task",
         %{"task_id" => "t1", "package" => "web", "task" => "test"}}

      assert {:noreply, new_state, :infinity} = Agent.handle_info(msg, state)
      on_exit(fn -> catch_error(Port.close(new_state.current_port)) end)

      lines = collect_port_output(new_state.current_port)

      refute Enum.any?(lines, &String.contains?(&1, "DXCORE_SHARD_INDEX"))
      refute Enum.any?(lines, &String.contains?(&1, "DXCORE_SHARD_COUNT"))
    end

    defp collect_port_output(port) do
      collect_port_output(port, [])
    end

    defp collect_port_output(port, acc) do
      receive do
        {^port, {:data, {_, line}}} ->
          collect_port_output(port, [line | acc])

        {^port, {:exit_status, _}} ->
          Enum.reverse(acc)
      after
        2000 ->
          Enum.reverse(acc)
      end
    end
  end

  describe "await_exit/1" do
    test "returns :normal when process exits normally" do
      pid = spawn(fn -> Process.sleep(50) end)
      assert :normal = Agent.await_exit(pid)
    end

    test "returns exit reason when process exits abnormally" do
      pid = spawn(fn -> Process.sleep(50) && exit({:shutdown, :failed}) end)
      assert {:shutdown, :failed} = Agent.await_exit(pid)
    end

    test "process is not linked to caller" do
      pid = spawn(fn -> Process.sleep(50) end)
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
      # If we get here, we weren't killed by a link
    end
  end
end
