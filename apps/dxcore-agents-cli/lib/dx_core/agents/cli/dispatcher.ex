defmodule DxCore.Agents.CLI.Dispatcher do
  @moduledoc false

  @shortdoc "Submit task graph and wait for completion"
  @help """
  Submit task graph and wait for completion.

  Usage: <build-system> --dry=json | dxcore dispatch [options]

  Options:
    --coordinator, -c <url>       Coordinator URL (required)
    --session-id, -s <id>         Session ID (required)
    --token, -t <token>           Auth token (required)
    --timeout, -T <seconds>       Max wait for completion (default: 900)
    --build-system, -b <system>   turbo|nx|generic|docker (default: "turbo")
    --work-dir, -w <path>         Working directory for dxcore.json scanning (default: ".")

  Reads task graph JSON from stdin, parses it using the build system adapter,
  and submits to the coordinator over WebSocket.\
  """

  use DxCore.Agents.CLI.Command
  use GenServer

  defstruct [
    :client,
    :ws_monitor,
    :session_id,
    :run_id,
    :timeout_ms,
    :tasks,
    :shard_config,
    :failure_strategy,
    :org_slug
  ]

  @default_timeout_s 900

  def run([flag | _]) when flag in ["--help", "-h"] do
    DxCore.Agents.CLI.Help.print_for(__MODULE__)
    throw(:help)
  end

  def run(args) do
    opts = parse_args(args)
    coordinator_url = Keyword.fetch!(opts, :coordinator)
    session_id = Keyword.fetch!(opts, :session_id)
    token = Keyword.fetch!(opts, :token)
    timeout_ms = Keyword.get(opts, :timeout, @default_timeout_s) * 1000
    build_system = Keyword.get(opts, :build_system, "turbo")
    failure_strategy = opts[:failure_strategy]

    org_slug =
      case DxCore.Agents.CLI.fetch_org_slug(coordinator_url, token) do
        {:ok, slug} ->
          IO.puts("[dispatcher:#{session_id}] Org: #{slug}")
          slug

        {:error, reason} ->
          IO.puts("[dispatcher:#{session_id}] Failed to fetch org: #{inspect(reason)}")
          System.halt(1)
      end

    work_dir = Keyword.get(opts, :work_dir, ".")
    shard_config = DxCore.Agents.ShardConfig.scan(work_dir)

    if map_size(shard_config) > 0 do
      IO.puts("[dispatcher:#{session_id}] Loaded shard config: #{map_size(shard_config)} entries")
    end

    IO.puts("[dispatcher:#{session_id}] Reading task graph from stdin (#{build_system})...")

    stdin = IO.read(:stdio, :eof)

    case read_stdin(stdin, build_system) do
      {:ok, tasks} ->
        IO.puts(
          "[dispatcher:#{session_id}] Parsed #{length(tasks)} tasks, connecting to coordinator..."
        )

        {:ok, pid} =
          GenServer.start(__MODULE__, %{
            coordinator_url: coordinator_url,
            session_id: session_id,
            token: token,
            tasks: tasks,
            timeout_ms: timeout_ms,
            shard_config: shard_config,
            failure_strategy: failure_strategy,
            org_slug: org_slug
          })

        case await_exit(pid) do
          :normal -> :ok
          _reason -> System.halt(1)
        end

      {:error, msg} ->
        IO.puts("[dispatcher:#{session_id}] #{msg}")
        System.halt(1)
    end
  end

  @doc """
  Parse stdin content into normalized task list using the appropriate adapter.

  Takes raw stdin string and build system name. Returns `{:ok, tasks}` or `{:error, message}`.
  """
  def read_stdin(input, build_system)

  def read_stdin(:eof, _build_system) do
    {:error,
     "No task graph provided on stdin. Pipe build system output, e.g.:\n  turbo run build --dry=json | dxcore dispatch ..."}
  end

  def read_stdin(input, build_system) when is_binary(input) do
    input = String.trim(input)

    if input == "" do
      {:error,
       "No task graph provided on stdin. Pipe build system output, e.g.:\n  turbo run build --dry=json | dxcore dispatch ..."}
    else
      case DxCore.Agents.BuildSystem.resolve(build_system) do
        {:ok, adapter} -> adapter.parse_graph(input)
        {:error, msg} -> {:error, msg}
      end
    end
  end

  defdelegate await_exit(pid), to: DxCore.Agents.CLI

  # --- GenServer Callbacks ---

  @impl GenServer
  def init(config) do
    ws_url = DxCore.Agents.CLI.http_to_ws(config.coordinator_url) <> "/dispatcher/websocket"

    topic = "dispatcher:#{config.org_slug}:#{config.session_id}"

    {:ok, client} =
      DxCore.Agents.WsClient.start_link(
        url: ws_url,
        topic: topic,
        caller: self(),
        token: config.token
      )

    Process.unlink(client)
    ws_monitor = Process.monitor(client)

    run_id = "run-#{System.system_time(:millisecond)}"

    state =
      struct!(__MODULE__, %{
        client: client,
        ws_monitor: ws_monitor,
        session_id: config.session_id,
        run_id: run_id,
        timeout_ms: config.timeout_ms,
        tasks: config.tasks,
        shard_config: config[:shard_config] || %{},
        failure_strategy: config[:failure_strategy],
        org_slug: config.org_slug
      })

    {:ok, state, state.timeout_ms}
  end

  @impl GenServer
  def handle_info({:channel_message, _topic, "task_started", payload}, state) do
    IO.puts("[coordinator] Task #{payload["task_id"]} assigned to #{payload["agent_id"]}")
    {:noreply, state, state.timeout_ms}
  end

  def handle_info({:channel_message, _topic, "task_completed", payload}, state) do
    status = if payload["exit_code"] == 0, do: "OK", else: "FAIL(#{payload["exit_code"]})"
    IO.puts("[coordinator] Task #{payload["task_id"]} #{status} (#{payload["duration_ms"]}ms)")
    {:noreply, state, state.timeout_ms}
  end

  def handle_info({:channel_message, _topic, "task_failed", payload}, state) do
    IO.puts("[coordinator] Task #{payload["task_id"]} FAILED: #{inspect(payload)}")
    {:noreply, state, state.timeout_ms}
  end

  def handle_info({:channel_message, _topic, "run_complete", payload}, state) do
    IO.puts("[coordinator] Run #{payload["run_id"]} complete: #{payload["status"]}")

    case payload["summary"] do
      nil -> :ok
      summary -> IO.puts(format_summary(summary))
    end

    if payload["status"] == "failed" do
      {:stop, {:shutdown, :failed}, state}
    else
      {:stop, :normal, state}
    end
  end

  def handle_info({:channel_message, _topic, "task_log", payload}, state) do
    IO.puts("[#{payload["agent_id"]}] #{payload["line"]}")
    {:noreply, state, state.timeout_ms}
  end

  def handle_info({:channel_message, _topic, "agent_connected", payload}, state) do
    IO.puts("[coordinator] Agent #{payload["agent_id"]} connected")
    {:noreply, state, state.timeout_ms}
  end

  def handle_info({:channel_message, _topic, "agent_disconnected", payload}, state) do
    IO.puts("[coordinator] Agent #{payload["agent_id"]} disconnected")
    {:noreply, state, state.timeout_ms}
  end

  def handle_info({:disconnected, reason}, state) do
    IO.puts("[dispatcher] Lost connection: #{inspect(reason)}, waiting for reconnect...")
    {:noreply, state, state.timeout_ms}
  end

  def handle_info({:channel_message, _topic, "presence_diff", _}, state) do
    {:noreply, state, state.timeout_ms}
  end

  def handle_info({:joined, _topic}, %{tasks: tasks} = state) when tasks != nil do
    IO.puts("[dispatcher:#{state.session_id}] Connected, submitting task graph...")

    payload = %{
      "run_id" => state.run_id,
      "tasks" => tasks,
      "shard_config" => state.shard_config || %{}
    }

    payload =
      case state.failure_strategy do
        nil -> payload
        strategy -> Map.put(payload, "failure_strategy", strategy)
      end

    reply =
      DxCore.Agents.WsClient.push_and_wait(state.client, "submit_graph", payload)

    case reply do
      {:ok, info} ->
        IO.puts(
          "[dispatcher:#{state.session_id}] Run #{state.run_id} submitted: #{info["total_tasks"]} tasks (#{info["cached_tasks"]} cached)"
        )

        {:noreply, %{state | tasks: nil}, state.timeout_ms}

      {:error, reason} ->
        IO.puts("[dispatcher:#{state.session_id}] Failed to submit graph: #{inspect(reason)}")

        {:stop, {:shutdown, :submit_failed}, state}
    end
  end

  def handle_info({:joined, _topic}, state) do
    IO.puts("[dispatcher:#{state.session_id}] Reconnected to coordinator")
    {:noreply, state, state.timeout_ms}
  end

  def handle_info({:topic_closed, _topic, _reason}, state) do
    IO.puts("[dispatcher:#{state.session_id}] Channel closed, waiting for reconnect...")
    {:noreply, state, state.timeout_ms}
  end

  def handle_info(:timeout, state) do
    IO.puts(
      "[dispatcher] Timeout waiting for run #{state.run_id} to complete (#{div(state.timeout_ms, 1000)}s)"
    )

    {:stop, {:shutdown, :timeout}, state}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, {:shutdown, :reconnect_timeout}},
        %{ws_monitor: ref} = state
      ) do
    IO.puts("[dispatcher] Coordinator unreachable after reconnect timeout. Exiting.")
    {:stop, {:shutdown, :reconnect_timeout}, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{ws_monitor: ref} = state) do
    IO.puts("[dispatcher] WsClient exited unexpectedly: #{inspect(reason)}. Stopping.")
    {:stop, {:shutdown, {:ws_client_down, reason}}, state}
  end

  def handle_info(msg, state) do
    IO.puts("[dispatcher:#{state.session_id}] Unexpected message: #{inspect(msg)}")
    {:noreply, state, state.timeout_ms}
  end

  @doc "Format a run summary map into a printable string."
  def format_summary(summary) do
    tasks_table = format_tasks_table(summary["tasks"])
    counts = summary["counts"]

    counts_line =
      "#{counts["passed"]} passed, #{counts["failed"]} failed, #{counts["skipped"]} skipped, #{counts["cached"]} cached"

    failure_details =
      case summary["failures"] do
        [] ->
          ""

        failures ->
          "\n\n── Failure Details ──────────────────────────\n" <> format_failures(failures)
      end

    """
    ── Run Summary ──────────────────────────────
    #{tasks_table}
     #{counts_line}#{failure_details}
    """
  end

  defp format_tasks_table(tasks) do
    tasks
    |> Enum.map(fn t ->
      status = format_task_status(t)
      agent = t["agent_id"] || "—"
      duration = format_duration(t["duration_ms"])

      " #{String.pad_trailing(t["task_id"], 30)} #{String.pad_trailing(agent, 10)} #{String.pad_trailing(status, 9)} #{duration}"
    end)
    |> Enum.join("\n")
  end

  defp format_task_status(%{"cached" => true}), do: "CACHED"
  defp format_task_status(%{"status" => "done"}), do: "OK"
  defp format_task_status(%{"status" => "failed", "exit_code" => code}), do: "FAIL(#{code})"
  defp format_task_status(%{"status" => "skipped"}), do: "SKIPPED"
  defp format_task_status(%{"status" => status}), do: String.upcase(status)

  defp format_duration(nil), do: "—"
  defp format_duration(ms) when ms < 1000, do: "#{ms}ms"
  defp format_duration(ms), do: "#{Float.round(ms / 1000, 1)}s"

  defp format_failures(failures) do
    failures
    |> Enum.map(fn f ->
      header = " #{f["task_id"]} (#{f["agent_id"]}, #{format_duration(f["duration_ms"])})"
      output = f["output"] || ""
      output_lines = output |> String.split("\n") |> Enum.map(&" > #{&1}") |> Enum.join("\n")
      "#{header}\n#{output_lines}"
    end)
    |> Enum.join("\n\n")
  end

  @doc false
  def parse_args(args) do
    {opts, _rest, _invalid} =
      OptionParser.parse(args,
        strict: [
          coordinator: :string,
          session_id: :string,
          token: :string,
          timeout: :integer,
          build_system: :string,
          work_dir: :string,
          failure_strategy: :string
        ],
        aliases: [
          c: :coordinator,
          s: :session_id,
          t: :token,
          T: :timeout,
          b: :build_system,
          w: :work_dir,
          f: :failure_strategy
        ]
      )

    opts
  end
end
