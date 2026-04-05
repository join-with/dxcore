defmodule DxCore.Agents.CLI.Agent do
  @moduledoc false

  @shortdoc "Connect to coordinator and execute assigned tasks"
  @help """
  Connect to coordinator and execute assigned tasks.

  Usage: dxcore agent [options]

  Options:
    --coordinator, -c <url>       Coordinator URL (required)
    --agent-id, -a <id>           Unique agent identifier (required)
    --session-id, -s <id>         Session ID (required)
    --token, -t <token>           Auth token (required)
    --work-dir, -w <path>         Working directory (default: ".")
    --build-system, -b <system>   turbo|nx|generic|docker (default: "turbo")
    --tags <tags>                 Comma-separated tags (e.g., gpu=true,arch=arm64)\
  """

  use DxCore.Agents.CLI.Command
  use GenServer

  defstruct [
    :client,
    :ws_monitor,
    :agent_id,
    :session_id,
    :work_dir,
    :adapter,
    :current_port,
    :current_task_id,
    :start_time,
    :capabilities
  ]

  @idle_timeout_ms 60_000

  # --- Public API ---

  def run([flag | _]) when flag in ["--help", "-h"] do
    DxCore.Agents.CLI.Help.print_for(__MODULE__)
    throw(:help)
  end

  def run(args) do
    {opts, _rest} = parse_args(args)
    coordinator_url = Keyword.fetch!(opts, :coordinator)
    agent_id = Keyword.fetch!(opts, :agent_id)
    session_id = Keyword.fetch!(opts, :session_id)
    token = Keyword.fetch!(opts, :token)
    work_dir = Keyword.get(opts, :work_dir, ".")
    build_system = Keyword.get(opts, :build_system, "turbo")
    tags_string = Keyword.get(opts, :tags)
    capabilities = detect_capabilities(tags_string)

    adapter =
      case DxCore.Agents.BuildSystem.resolve(build_system) do
        {:ok, mod} ->
          mod

        {:error, msg} ->
          IO.puts("[agent:#{agent_id}@#{session_id}] #{msg}")
          System.halt(1)
      end

    IO.puts("[agent:#{agent_id}@#{session_id}] Connecting to coordinator at #{coordinator_url}")

    # Use GenServer.start (not start_link) so the monitor alone observes the
    # exit reason. A link would propagate {:shutdown, _} exits and crash the
    # caller before the :DOWN message arrives.
    {:ok, pid} =
      GenServer.start(__MODULE__, %{
        coordinator_url: coordinator_url,
        agent_id: agent_id,
        session_id: session_id,
        token: token,
        work_dir: work_dir,
        adapter: adapter,
        capabilities: capabilities
      })

    case await_exit(pid) do
      :normal -> :ok
      _reason -> System.halt(1)
    end
  end

  defdelegate await_exit(pid), to: DxCore.Agents.CLI

  # --- GenServer Callbacks ---

  @impl GenServer
  def init(config) do
    ws_url = DxCore.Agents.CLI.http_to_ws(config.coordinator_url) <> "/agent/websocket"

    {:ok, client} =
      DxCore.Agents.WsClient.start_link(
        url: ws_url,
        topic: "agent:#{config.session_id}",
        caller: self(),
        token: config.token
      )

    Process.unlink(client)
    ws_monitor = Process.monitor(client)

    state =
      struct!(__MODULE__, %{
        client: client,
        ws_monitor: ws_monitor,
        agent_id: config.agent_id,
        session_id: config.session_id,
        work_dir: config.work_dir,
        adapter: config.adapter,
        capabilities: config.capabilities
      })

    log(state, "Waiting for connection...")
    {:ok, state, @idle_timeout_ms}
  end

  @impl GenServer
  def handle_info({:channel_message, _topic, "assign_task", payload}, state) do
    if state.current_port != nil do
      log(state, "Warning: task already in progress, ignoring")
      {:noreply, state, idle_timeout(state)}
    else
      %{"task_id" => task_id, "package" => package, "task" => task} = payload
      shard = payload["shard"]
      log(state, "Executing task #{task_id}")

      try do
        port = open_task_port(state.adapter, state.work_dir, package, task, shard)

        new_state = %{
          state
          | current_port: port,
            current_task_id: task_id,
            start_time: System.monotonic_time(:millisecond)
        }

        {:noreply, new_state, idle_timeout(new_state)}
      rescue
        e ->
          log(state, "Failed to start task #{task_id}: #{Exception.message(e)}")

          DxCore.Agents.WsClient.push(state.client, "task_result", %{
            "task_id" => task_id,
            "exit_code" => -1,
            "duration_ms" => 0
          })

          {:noreply, state, @idle_timeout_ms}
      end
    end
  end

  def handle_info({port, {:data, {_type, line}}}, %{current_port: port} = state) do
    log(state, line)

    DxCore.Agents.WsClient.push(state.client, "task_log", %{
      "task_id" => state.current_task_id,
      "line" => line
    })

    {:noreply, state, idle_timeout(state)}
  end

  def handle_info({port, {:exit_status, exit_code}}, %{current_port: port} = state) do
    duration_ms = System.monotonic_time(:millisecond) - state.start_time
    log(state, "Task #{state.current_task_id} exit=#{exit_code} (#{duration_ms}ms)")

    DxCore.Agents.WsClient.push(state.client, "task_result", %{
      "task_id" => state.current_task_id,
      "exit_code" => exit_code,
      "duration_ms" => duration_ms
    })

    new_state = %{state | current_port: nil, current_task_id: nil, start_time: nil}
    {:noreply, new_state, @idle_timeout_ms}
  end

  def handle_info({:channel_message, _topic, "shutdown", %{"reason" => reason}}, state) do
    log(state, "Shutting down: #{reason}")

    if state.current_port do
      kill_port(state.current_port)

      duration_ms = System.monotonic_time(:millisecond) - state.start_time

      DxCore.Agents.WsClient.push(state.client, "task_result", %{
        "task_id" => state.current_task_id,
        "exit_code" => -1,
        "duration_ms" => duration_ms
      })
    end

    {:stop, :normal, state}
  end

  def handle_info({:channel_message, _topic, "presence_diff", _}, state) do
    {:noreply, state, idle_timeout(state)}
  end

  def handle_info({:joined, _topic}, state) do
    log(state, "Connected, announcing ready")

    DxCore.Agents.WsClient.push(state.client, "agent_ready", %{
      "agent_id" => state.agent_id,
      "capabilities" => state.capabilities
    })

    {:noreply, state, idle_timeout(state)}
  end

  def handle_info({:topic_closed, _topic, _reason}, state) do
    log(state, "Channel closed, waiting for reconnect...")
    {:noreply, state, idle_timeout(state)}
  end

  def handle_info({:disconnected, reason}, state) do
    log(state, "Lost connection: #{inspect(reason)}, waiting for reconnect...")
    {:noreply, state, idle_timeout(state)}
  end

  def handle_info(:timeout, state) do
    log(state, "No tasks for #{div(@idle_timeout_ms, 1000)}s, exiting")
    {:stop, :normal, state}
  end

  # Port messages arriving after exit_status (port already cleared from state)
  def handle_info({_port, {:data, _}}, state) do
    {:noreply, state, idle_timeout(state)}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, {:shutdown, :reconnect_timeout}},
        %{ws_monitor: ref} = state
      ) do
    log(state, "Coordinator unreachable after reconnect timeout. Exiting.")
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{ws_monitor: ref} = state) do
    log(state, "WsClient exited unexpectedly: #{inspect(reason)}. Stopping.")
    {:stop, {:shutdown, {:ws_client_down, reason}}, state}
  end

  def handle_info(msg, state) do
    log(state, "Unexpected message: #{inspect(msg)}")
    {:noreply, state, idle_timeout(state)}
  end

  # --- Private Helpers ---

  defp idle_timeout(%{current_port: nil}), do: @idle_timeout_ms
  defp idle_timeout(_state), do: :infinity

  defp log(%{agent_id: agent_id, session_id: session_id}, msg) do
    IO.puts("[agent:#{agent_id}@#{session_id}] #{msg}")
  end

  defp kill_port(port) do
    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        nil -> nil
      end

    try do
      Port.close(port)
    rescue
      ArgumentError -> :already_closed
    end

    if os_pid do
      try do
        System.cmd("kill", ["-9", to_string(os_pid)], stderr_to_stdout: true)
      rescue
        _ -> :ok
      end
    end

    :ok
  end

  defp open_task_port(adapter, work_dir, package, task, shard) do
    {executable, args} = adapter.task_command(work_dir, package, task)

    env =
      case shard do
        %{"index" => i, "count" => c} ->
          [
            {~c"DXCORE_SHARD_INDEX", to_charlist(i)},
            {~c"DXCORE_SHARD_COUNT", to_charlist(c)}
          ]

        _ ->
          []
      end

    Port.open({:spawn_executable, executable}, [
      {:args, args},
      :binary,
      :exit_status,
      :stderr_to_stdout,
      {:cd, String.to_charlist(work_dir)},
      {:line, 4096},
      {:env, env}
    ])
  end

  @doc false
  def parse_args(args) do
    {opts, rest, _invalid} =
      OptionParser.parse(args,
        strict: [
          coordinator: :string,
          agent_id: :string,
          work_dir: :string,
          session_id: :string,
          token: :string,
          build_system: :string,
          tags: :string
        ],
        aliases: [
          c: :coordinator,
          a: :agent_id,
          w: :work_dir,
          s: :session_id,
          t: :token,
          b: :build_system
        ]
      )

    {opts, rest}
  end

  @doc false
  def detect_capabilities(tags_string) do
    %{
      "cpu_cores" => :erlang.system_info(:logical_processors),
      "memory_mb" => detect_memory_mb(),
      "disk_free_mb" => nil,
      "tags" => parse_tags(tags_string)
    }
  end

  @doc false
  def parse_tags(nil), do: %{}
  def parse_tags(""), do: %{}

  def parse_tags(str) do
    str
    |> String.split(",")
    |> Enum.map(&String.split(&1, "=", parts: 2))
    |> Enum.into(%{}, fn
      [k, v] -> {String.trim(k), String.trim(v)}
      [k] -> {String.trim(k), "true"}
    end)
  end

  defp detect_memory_mb do
    case File.read("/proc/meminfo") do
      {:ok, content} ->
        case Regex.run(~r/MemTotal:\s+(\d+)\s+kB/, content) do
          [_, kb_str] -> div(String.to_integer(kb_str), 1024)
          _ -> nil
        end

      {:error, _} ->
        nil
    end
  end
end
