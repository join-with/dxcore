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
    --tags <tags>                 Comma-separated tags (e.g., gpu=true,arch=arm64)
    --command-template <tpl>      Override commands with template (e.g., "make -C {package} {task}")
  """

  use DxCore.Agents.CLI.Command
  use GenServer

  alias DxCore.Agents.CLI.LostCoordinator

  defstruct [
    :client,
    :ws_monitor,
    :agent_id,
    :session_id,
    :work_dir,
    :adapter,
    :current_port,
    :current_task_id,
    :current_run_id,
    :start_time,
    :capabilities,
    :command_template,
    :org_slug,
    # Starts a WsClient for this agent's topic, `{:ok, pid}`.
    :connect,
    # A task's result that ended while the coordinator was lost, to report
    # once the agent rejoins.
    :lost_result,
    # When the connection dropped (monotonic ms), nil while connected.
    :lost_at,
    # How long a task runs on once the coordinator is lost (LostCoordinator).
    reconnect_timeout_ms: LostCoordinator.reconnect_timeout_ms(),
    task_grace_ms: LostCoordinator.task_grace_ms(),
    kill_after_ms: LostCoordinator.kill_after_ms()
  ]

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
    command_template = Keyword.get(opts, :command_template)

    org_slug =
      case DxCore.Agents.CLI.fetch_org_slug(coordinator_url, token) do
        {:ok, slug} ->
          IO.puts("[agent:#{agent_id}@#{session_id}] Org: #{slug}")
          slug

        {:error, reason} ->
          IO.puts("[agent:#{agent_id}@#{session_id}] Failed to fetch org: #{inspect(reason)}")
          System.halt(1)
      end

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
        capabilities: capabilities,
        command_template: command_template,
        org_slug: org_slug
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

    topic = "agent:#{config.org_slug}:#{config.session_id}"
    agent = self()

    reconnect_timeout_ms =
      Map.get(config, :reconnect_timeout_ms, LostCoordinator.reconnect_timeout_ms())

    connect =
      Map.get(config, :connect) ||
        fn ->
          DxCore.Agents.WsClient.start_link(
            url: ws_url,
            topic: topic,
            caller: agent,
            token: config.token,
            reconnect_timeout_ms: reconnect_timeout_ms
          )
        end

    {:ok, client} = connect.()
    Process.unlink(client)
    ws_monitor = Process.monitor(client)

    state =
      struct!(__MODULE__, %{
        client: client,
        ws_monitor: ws_monitor,
        connect: connect,
        agent_id: config.agent_id,
        session_id: config.session_id,
        work_dir: config.work_dir,
        adapter: config.adapter,
        capabilities: config.capabilities,
        command_template: config.command_template,
        org_slug: config.org_slug,
        reconnect_timeout_ms: reconnect_timeout_ms,
        task_grace_ms: Map.get(config, :task_grace_ms, LostCoordinator.task_grace_ms()),
        kill_after_ms: Map.get(config, :kill_after_ms, LostCoordinator.kill_after_ms())
      })

    log(state, "Waiting for connection...")
    {:ok, state}
  end

  @impl GenServer
  def handle_info({:channel_message, _topic, "assign_task", payload}, state) do
    if state.current_port != nil do
      log(state, "Warning: task already in progress, ignoring")
      {:noreply, state}
    else
      %{"task_id" => task_id, "run_id" => run_id} = payload
      shard = payload["shard"]
      log(state, "Executing task #{task_id}")

      case resolve_command(state.command_template, payload) do
        {:ok, command} ->
          try do
            port = open_task_port(state.work_dir, command, shard)

            new_state = %{
              state
              | current_port: port,
                current_task_id: task_id,
                current_run_id: run_id,
                start_time: System.monotonic_time(:millisecond)
            }

            {:noreply, new_state, :infinity}
          rescue
            e ->
              log(state, "Failed to start task #{task_id}: #{Exception.message(e)}")

              DxCore.Agents.WsClient.push(state.client, "task_result", %{
                "task_id" => task_id,
                "run_id" => run_id,
                "exit_code" => -1,
                "duration_ms" => 0
              })

              {:noreply, state}
          end

        {:error, reason} ->
          log(state, "Command template error for #{task_id}: #{reason}")

          DxCore.Agents.WsClient.push(state.client, "task_result", %{
            "task_id" => task_id,
            "run_id" => run_id,
            "exit_code" => -1,
            "duration_ms" => 0
          })

          {:noreply, state}
      end
    end
  end

  def handle_info({port, {:data, {_type, line}}}, %{current_port: port} = state) do
    # `{:line, _}` ports split long lines at a fixed byte size, which can cut a
    # multibyte UTF-8 char in half and yield an invalid-UTF-8 chunk. Both sinks
    # below reject that (`IO.puts` -> ArgumentError, `Jason.encode` -> error),
    # so scrub to valid UTF-8 first. See #4144.
    safe_line = sanitize_log_line(line)

    log(state, safe_line)

    # With the coordinator lost (no client), the line only goes to the log.
    if state.client do
      DxCore.Agents.WsClient.push(state.client, "task_log", %{
        "task_id" => state.current_task_id,
        "line" => safe_line
      })
    end

    {:noreply, state, :infinity}
  end

  def handle_info({port, {:exit_status, exit_code}}, %{current_port: port} = state) do
    duration_ms = System.monotonic_time(:millisecond) - state.start_time
    log(state, "Task #{state.current_task_id} exit=#{exit_code} (#{duration_ms}ms)")

    result = %{
      "task_id" => state.current_task_id,
      "run_id" => state.current_run_id,
      "exit_code" => exit_code,
      "duration_ms" => duration_ms
    }

    new_state = %{
      state
      | current_port: nil,
        current_task_id: nil,
        current_run_id: nil,
        start_time: nil
    }

    if state.client do
      DxCore.Agents.WsClient.push(state.client, "task_result", result)
      {:noreply, new_state}
    else
      reconnect_to_report(new_state, result)
    end
  end

  def handle_info({:channel_message, _topic, "shutdown", %{"reason" => reason}}, state) do
    log(state, "Shutting down: #{reason}")

    if state.current_port do
      kill_port(state.current_port)

      duration_ms = System.monotonic_time(:millisecond) - state.start_time

      DxCore.Agents.WsClient.push(state.client, "task_result", %{
        "task_id" => state.current_task_id,
        "run_id" => state.current_run_id,
        "exit_code" => -1,
        "duration_ms" => duration_ms
      })
    end

    {:stop, :normal, state}
  end

  def handle_info({:channel_message, _topic, "presence_diff", _}, state) do
    {:noreply, state}
  end

  # Back after losing the coordinator mid-task: announce the finished task as
  # this agent's (so the coordinator keeps it here), report its result, and
  # stop once that push is on the wire, as the agent would have when it lost
  # the coordinator idle.
  def handle_info({:joined, _topic}, %{lost_result: %{} = result} = state) do
    DxCore.Agents.WsClient.push(state.client, "agent_ready", %{
      "agent_id" => state.agent_id,
      "capabilities" => state.capabilities,
      "current_task" => Map.take(result, ["task_id", "run_id"])
    })

    reply =
      try do
        DxCore.Agents.WsClient.push_sync(state.client, "task_result", result)
      catch
        :exit, reason -> {:error, reason}
      end

    case reply do
      :ok ->
        log(state, "Reported task #{result["task_id"]}'s result after reconnecting. Exiting.")

      error ->
        log(
          state,
          "Could not report task #{result["task_id"]}'s result (#{inspect(error)}). Exiting."
        )
    end

    {:stop, :normal, state}
  end

  def handle_info({:joined, _topic}, state) do
    state = %{state | lost_at: nil}
    tags = state.capabilities["tags"] || %{}

    if tags == %{} do
      log(state, "Connected with no tags")
    else
      log(state, "Connected with tags: #{inspect(tags)}")
    end

    log(state, "Announcing ready")

    # `current_task` tells the coordinator what this agent is running (nil
    # when idle), so after a reconnect it keeps that task on this agent,
    # releases any other it thinks this agent holds, and does not push work
    # to a busy agent.
    DxCore.Agents.WsClient.push(state.client, "agent_ready", %{
      "agent_id" => state.agent_id,
      "capabilities" => state.capabilities,
      "current_task" => current_task(state)
    })

    {:noreply, state}
  end

  def handle_info(
        {:topic_closed, _topic, {:failed_to_join, %{"reason" => "session_finished"}}},
        state
      ) do
    log(state, "Session already finished, exiting")
    {:stop, :normal, state}
  end

  def handle_info({:topic_closed, _topic, _reason}, state) do
    log(state, "Channel closed, waiting for reconnect...")
    {:noreply, state}
  end

  # Every failed reconnect attempt says so again; the first one starts the
  # clock a running task is stopped by.
  def handle_info({:disconnected, reason}, state) do
    log(state, "Lost connection: #{inspect(reason)}, waiting for reconnect...")
    {:noreply, %{state | lost_at: state.lost_at || System.monotonic_time(:millisecond)}}
  end

  # Port messages arriving after exit_status (port already cleared from state)
  def handle_info({_port, {:data, _}}, state) do
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, {:shutdown, :reconnect_timeout}},
        %{ws_monitor: ref, lost_result: %{} = result} = state
      ) do
    log(
      state,
      "Coordinator still unreachable: could not report task #{result["task_id"]}'s result " <>
        "(exit #{result["exit_code"]}). Exiting."
    )

    {:stop, :normal, state}
  end

  # A running task goes on for `task_grace_ms` past the reconnect window:
  # killing it mid-way (a `pulumi up`) left half-applied state that the next
  # deploy made worse (#12435). It is stopped after that, since the
  # coordinator holds the task for this agent only so long (LostCoordinator).
  # The agent reconnects once the task has ended, to report its result.
  def handle_info(
        {:DOWN, ref, :process, _pid, {:shutdown, :reconnect_timeout}},
        %{ws_monitor: ref, current_port: port} = state
      )
      when port != nil do
    now = System.monotonic_time(:millisecond)
    lost_at = state.lost_at || now - state.reconnect_timeout_ms
    stop_in = max(lost_at + state.reconnect_timeout_ms + state.task_grace_ms - now, 0)

    log(
      state,
      "Coordinator unreachable after reconnect timeout. Letting task #{state.current_task_id} " <>
        "run for up to #{div(stop_in, 1000)} s more, then reconnecting to report it."
    )

    Process.send_after(self(), {:lost_task_stop, state.current_task_id}, stop_in)
    {:noreply, %{state | client: nil, ws_monitor: nil, lost_at: lost_at}, :infinity}
  end

  def handle_info(
        {:lost_task_stop, task_id},
        %{client: nil, current_task_id: task_id, current_port: port} = state
      )
      when port != nil do
    log(
      state,
      "Task #{task_id} is still running and the coordinator is still unreachable. " <>
        "Sending it SIGTERM; SIGKILL in #{div(state.kill_after_ms, 1000)} s if it is still running."
    )

    signal_port(port, "TERM")
    Process.send_after(self(), {:lost_task_kill, task_id}, state.kill_after_ms)
    {:noreply, state, :infinity}
  end

  def handle_info(
        {:lost_task_kill, task_id},
        %{client: nil, current_task_id: task_id, current_port: port} = state
      )
      when port != nil do
    log(state, "Task #{task_id} is still running after SIGTERM. Sending it SIGKILL.")
    kill_port(port)

    result = %{
      "task_id" => task_id,
      "run_id" => state.current_run_id,
      "exit_code" => -1,
      "duration_ms" => System.monotonic_time(:millisecond) - state.start_time
    }

    reconnect_to_report(
      %{state | current_port: nil, current_task_id: nil, current_run_id: nil, start_time: nil},
      result
    )
  end

  # The task ended before its stop came due.
  def handle_info({stop, _task_id}, state) when stop in [:lost_task_stop, :lost_task_kill] do
    {:noreply, state}
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
    {:noreply, state}
  end

  # --- Private Helpers ---

  defp reconnect_to_report(state, result) do
    log(state, "Reconnecting to report task #{result["task_id"]}'s result...")

    case state.connect.() do
      {:ok, client} ->
        Process.unlink(client)
        ws_monitor = Process.monitor(client)
        {:noreply, %{state | client: client, ws_monitor: ws_monitor, lost_result: result}}

      error ->
        log(
          state,
          "Could not reconnect (#{inspect(error)}): task #{result["task_id"]}'s result is lost. Exiting."
        )

        {:stop, :normal, state}
    end
  end

  defp current_task(%{current_task_id: task_id, current_run_id: run_id})
       when is_binary(task_id) and is_binary(run_id),
       do: %{"task_id" => task_id, "run_id" => run_id}

  defp current_task(_state), do: nil

  defp log(%{agent_id: agent_id, session_id: session_id}, msg) do
    IO.puts("[agent:#{agent_id}@#{session_id}] #{msg}")
  end

  # Replace invalid UTF-8 byte sequences (e.g. a multibyte char split across a
  # `{:line, _}` port chunk boundary) with U+FFFD so the line is safe to write
  # to stdout and to JSON-encode for the coordinator. Valid lines pass through
  # untouched. See #4144.
  @doc false
  def sanitize_log_line(line) when is_binary(line) do
    if String.valid?(line), do: line, else: scrub_utf8(line, <<>>)
  end

  defp scrub_utf8(<<>>, acc), do: acc

  defp scrub_utf8(<<grapheme::utf8, rest::binary>>, acc),
    do: scrub_utf8(rest, <<acc::binary, grapheme::utf8>>)

  defp scrub_utf8(<<_invalid, rest::binary>>, acc),
    do: scrub_utf8(rest, <<acc::binary, "�">>)

  # SIGKILL goes to the task's whole process tree: a killed parent does not
  # take its children with it, so a `pulumi up` under `pnpm` would run on. The
  # tree is read before the kill, while the children are still the task's.
  # The port is closed first, since its `exit_status` waits for EOF on the
  # task's output, which an orphan that keeps it open never sends.
  defp kill_port(port) do
    os_pid = port_os_pid(port)
    tree = if os_pid, do: [os_pid | descendants(os_pid)], else: []

    try do
      Port.close(port)
    rescue
      ArgumentError -> :already_closed
    end

    signal_os_pids(tree, "KILL")
  end

  # SIGTERM goes to the task's own process only: the tools it runs (`turbo`,
  # `pnpm`) pass it on to theirs, and a second copy straight from the agent
  # could turn a graceful cancel into a forced one (Pulumi stops at once on a
  # second interrupt). The port stays open, so the task's exit arrives as
  # `exit_status`.
  defp signal_port(port, signal) do
    case port_os_pid(port) do
      nil -> :ok
      os_pid -> signal_os_pids([os_pid], signal)
    end
  end

  defp port_os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> pid
      nil -> nil
    end
  end

  defp signal_os_pids([], _signal), do: :ok

  defp signal_os_pids(os_pids, signal) do
    System.cmd("kill", ["-#{signal}" | Enum.map(os_pids, &to_string/1)], stderr_to_stdout: true)
    :ok
  rescue
    _ -> :ok
  end

  # Every process below `os_pid`, read from `ps`; none when `ps` fails.
  @doc false
  def descendants(os_pid) do
    case System.cmd("ps", ["-e", "-o", "pid=,ppid="], stderr_to_stdout: true) do
      {out, 0} ->
        children =
          out
          |> String.split("\n", trim: true)
          |> Enum.flat_map(fn line ->
            case String.split(line) do
              [pid, ppid] -> [{String.to_integer(ppid), String.to_integer(pid)}]
              _ -> []
            end
          end)
          |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

        collect_descendants(Map.get(children, os_pid, []), children, [])

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp collect_descendants([], _children, acc), do: Enum.reverse(acc)

  defp collect_descendants([pid | rest], children, acc) do
    if pid in acc,
      do: collect_descendants(rest, children, acc),
      else: collect_descendants(Map.get(children, pid, []) ++ rest, children, [pid | acc])
  end

  defp open_task_port(work_dir, command, shard) do
    [exe | args] = String.split(command)
    executable = System.find_executable(exe) || exe

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
          tags: :string,
          command_template: :string
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

  @doc false
  def resolve_command(nil, payload) do
    case payload["command"] do
      nil -> {:error, "Payload missing required \"command\" field"}
      cmd -> {:ok, cmd}
    end
  end

  def resolve_command(template, payload) do
    params = %{
      "package" => payload["package"] || "",
      "task" => payload["task"] || "",
      "hash" => payload["hash"] || "",
      "shard_index" => shard_value(payload, "index"),
      "shard_count" => shard_value(payload, "count"),
      "command" => payload["command"] || ""
    }

    DxCore.Agents.CLI.CommandTemplate.interpolate(template, params)
  end

  defp shard_value(payload, key) do
    case get_in(payload, ["shard", key]) do
      nil -> nil
      val -> to_string(val)
    end
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
