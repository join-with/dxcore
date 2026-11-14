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
    --timeout, -T <seconds>       Max idle wait for completion (default: 900)
    --build-system, -b <system>   turbo|nx|generic|docker (default: "turbo")
    --work-dir, -w <path>         Working directory for dxcore.json scanning (default: ".")
    --deadline <time>             ISO 8601 time with an offset: no new tasks after it,
                                  exit 75 when tasks are left (default: none)
    --hard-stop-after <seconds>   Cancel tasks still running this long after the
                                  deadline (default: 120)
    --result-file <path>          Write the coordinator's verdict as JSON
                                  (passed, failed or unfinished, with the counts)

  With --deadline the coordinator owns the run: it stops handing out tasks at
  the deadline, cancels the rest after --hard-stop-after, and decides the exit
  code (0 passed, 75 unfinished, 1 failed). --timeout is ignored with it.

  Reads task graph JSON from stdin, parses it using the build system adapter,
  and submits to the coordinator over WebSocket.\
  """

  use DxCore.Agents.CLI.Command
  use GenServer

  alias DxCore.Agents.CLI.Dispatcher.{Deadline, Result, RunReader}

  # How often the backstop asks again while the run has no verdict.
  @verdict_retry_ms 30_000

  defstruct [
    :client,
    :ws_monitor,
    :session_id,
    :run_id,
    :timeout_ms,
    :tasks,
    :shard_config,
    :failure_strategy,
    :org_slug,
    # The coordinator's id for the run (the submit reply's run_id), which
    # cancel_run names.
    :coordinator_run_id,
    :deadline,
    :coordinator_url,
    :token,
    :result_file,
    :read_run,
    # A deadline run: the coordinator owns its clock, verdict and end.
    managed: false,
    # How long after the hard stop the backstop first asks for the verdict.
    verdict_grace_ms: 15_000,
    hard_stop_after_ms: 120_000,
    failed: false,
    running: MapSet.new(),
    connected_agents: 0,
    # Tasks whose result has been printed, so a replayed snapshot and the live
    # event for the same task report it once.
    finished: MapSet.new()
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

    result_file = opts[:result_file]

    deadline_opts =
      case Deadline.options(opts) do
        {:ok, deadline_opts} ->
          deadline_opts

        {:error, msg} ->
          IO.puts("[dispatcher:#{session_id}] #{msg}")
          System.halt(1)
      end

    managed = deadline_opts.deadline != nil

    timeout_ms =
      cond do
        managed and Keyword.has_key?(opts, :timeout) ->
          IO.puts(
            "[dispatcher:#{session_id}] --timeout is ignored with --deadline: the coordinator ends the run"
          )

          :infinity

        managed ->
          :infinity

        true ->
          timeout_ms
      end

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
            org_slug: org_slug,
            deadline: deadline_opts.deadline,
            hard_stop_after_ms: deadline_opts.hard_stop_after_ms,
            result_file: result_file,
            managed: managed
          })

        case await_exit_code(pid) do
          0 -> :ok
          code -> System.halt(code)
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

  @doc "Wait for the dispatcher `pid` to stop; its process exit code (`Deadline.exit_code/1`)."
  def await_exit_code(pid), do: pid |> await_exit() |> Deadline.exit_code()

  # --- GenServer Callbacks ---

  @impl GenServer
  def init(config) do
    ws_url = DxCore.Agents.CLI.http_to_ws(config.coordinator_url) <> "/dispatcher/websocket"

    # Generate run_id BEFORE connecting so we can use it in the (run-scoped) topic
    run_id = "run-#{System.system_time(:millisecond)}"
    topic = "dispatcher:#{config.org_slug}:#{run_id}"

    {:ok, client} =
      DxCore.Agents.WsClient.start_link(
        url: ws_url,
        topic: topic,
        caller: self(),
        token: config.token
      )

    Process.unlink(client)
    ws_monitor = Process.monitor(client)

    state =
      struct!(
        __MODULE__,
        Map.merge(
          %{
            client: client,
            ws_monitor: ws_monitor,
            session_id: config.session_id,
            run_id: run_id,
            timeout_ms: config.timeout_ms,
            tasks: config.tasks,
            shard_config: config[:shard_config] || %{},
            failure_strategy: config[:failure_strategy],
            org_slug: config.org_slug,
            coordinator_url: config.coordinator_url,
            token: config.token,
            read_run: &RunReader.fetch/3
          },
          Map.take(config, [:deadline, :hard_stop_after_ms, :result_file, :managed])
        )
      )

    {:ok, state, state.timeout_ms}
  end

  @impl GenServer
  def handle_info({:channel_message, _topic, "task_started", payload}, state) do
    IO.puts("[coordinator] Task #{payload["task_id"]} assigned to #{payload["agent_id"]}")

    {:noreply, %{state | running: MapSet.put(state.running, payload["task_id"])},
     state.timeout_ms}
  end

  def handle_info({:channel_message, _topic, "task_completed", payload}, state) do
    task_id = payload["task_id"]
    state = %{state | running: MapSet.delete(state.running, task_id)}

    if MapSet.member?(state.finished, task_id) do
      {:noreply, state, state.timeout_ms}
    else
      status = if payload["exit_code"] == 0, do: "OK", else: "FAIL(#{payload["exit_code"]})"
      IO.puts("[coordinator] Task #{task_id} #{status} (#{payload["duration_ms"]}ms)")

      {:noreply,
       %{
         state
         | finished: MapSet.put(state.finished, task_id),
           failed: state.failed or payload["exit_code"] != 0
       }, state.timeout_ms}
    end
  end

  # Sent by the coordinator when this dispatcher rejoins its run (after a
  # reconnect or a coordinator restart): the run's summary so far. Tasks
  # already reported are skipped; a finished run ends the dispatch exactly as
  # `run_complete` does.
  def handle_info({:channel_message, _topic, "run_snapshot", payload}, state) do
    case parse_snapshot(payload) do
      {:ok, status, tasks, pending} ->
        state = report_snapshot_tasks(tasks, state)

        IO.puts(
          "[dispatcher:#{state.session_id}] Run #{state.run_id} resumed: " <>
            "#{MapSet.size(state.finished)} tasks finished, #{pending} pending (#{status})"
        )

        # A finished run's run_complete follows the snapshot; it ends the dispatch.
        {:noreply, state, state.timeout_ms}

      :error ->
        IO.puts("[dispatcher:#{state.session_id}] Ignoring malformed run_snapshot")
        {:noreply, state, state.timeout_ms}
    end
  end

  def handle_info({:channel_message, _topic, "task_failed", payload}, state) do
    IO.puts("[coordinator] Task #{payload["task_id"]} FAILED: #{inspect(payload)}")
    {:noreply, state, state.timeout_ms}
  end

  def handle_info({:channel_message, _topic, "run_complete", payload}, state) do
    print_completion(payload)

    case Result.parse(payload["result"]) do
      {:ok, result} -> finish_with(result, state)
      :error -> finish_without_result(payload["status"], state)
    end
  end

  def handle_info({:channel_message, _topic, "task_log", payload}, state) do
    IO.puts("[#{payload["agent_id"]}] #{payload["line"]}")
    {:noreply, state, state.timeout_ms}
  end

  def handle_info({:channel_message, _topic, "agent_connected", payload}, state) do
    IO.puts("[coordinator] Agent #{payload["agent_id"]} connected")
    {:noreply, %{state | connected_agents: state.connected_agents + 1}, state.timeout_ms}
  end

  def handle_info({:channel_message, _topic, "agent_disconnected", payload}, state) do
    IO.puts("[coordinator] Agent #{payload["agent_id"]} disconnected")
    new_count = max(state.connected_agents - 1, 0)

    if new_count == 0 do
      IO.puts(
        "[dispatcher:#{state.session_id}] All agents disconnected, tasks may still be pending"
      )
    end

    {:noreply, %{state | connected_agents: new_count}, state.timeout_ms}
  end

  def handle_info({:disconnected, reason}, state) do
    IO.puts("[dispatcher] Lost connection: #{inspect(reason)}, waiting for reconnect...")
    {:noreply, state, state.timeout_ms}
  end

  def handle_info({:channel_message, _topic, "presence_diff", _}, state) do
    {:noreply, state, state.timeout_ms}
  end

  # A dispatch that starts at its deadline submits nothing (the coordinator
  # refuses a past deadline): every task is left, and an unfinished gate is
  # not a failed one. The margin covers clock skew with the coordinator.
  def handle_info({:joined, _topic}, %{tasks: tasks, managed: true} = state)
      when tasks != nil do
    if DateTime.compare(state.deadline, DateTime.add(DateTime.utc_now(), 5, :second)) != :gt do
      unfinished_at_start(state)
    else
      submit_graph(state)
    end
  end

  def handle_info({:joined, _topic}, %{tasks: tasks} = state) when tasks != nil,
    do: submit_graph(state)

  def handle_info({:joined, _topic}, state) do
    # The coordinator replays the run on a resume join, but gives up after a
    # few tries: read the run once, in case its run_complete was missed.
    IO.puts("[dispatcher:#{state.session_id}] Reconnected to coordinator")
    poll_verdict(state, :once)
  end

  # Read-only backstop for a deadline run whose run_complete never arrives.
  # The coordinator owns the clock; this only asks for the verdict.
  def handle_info(:read_verdict, state), do: poll_verdict(state, :again)

  def handle_info(
        {:topic_closed, _topic, {:failed_to_join, %{"reason" => "session_finished"}}},
        state
      ) do
    IO.puts("[dispatcher:#{state.session_id}] Session already finished; reading the run's result")
    read_result(state, {:shutdown, :session_finished})
  end

  def handle_info({:topic_closed, _topic, {:failed_to_join, %{"reason" => reason}}}, state)
      when reason in ["run_not_found", "invalid_join_params"] do
    IO.puts(
      "[dispatcher:#{state.session_id}] Coordinator refused to resume run #{state.run_id}: #{reason}"
    )

    read_result(state, {:shutdown, :resume_refused})
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

  @finished_statuses ["done", "failed", "skipped"]

  defp parse_snapshot(%{"status" => status, "summary" => %{"tasks" => tasks}} = payload)
       when is_binary(status) and is_list(tasks) do
    if Enum.all?(
         tasks,
         &match?(%{"task_id" => id, "status" => s} when is_binary(id) and is_binary(s), &1)
       ) do
      pending = Map.get(payload, "pending")
      {:ok, status, tasks, if(is_integer(pending), do: pending, else: "?")}
    else
      :error
    end
  end

  defp parse_snapshot(_payload), do: :error

  defp report_snapshot_tasks(tasks, state) do
    Enum.reduce(tasks, state, fn task, acc ->
      task_id = task["task_id"]

      cond do
        task["status"] == "running" ->
          %{acc | running: MapSet.put(acc.running, task_id)}

        # Released and queued again, or never started: not running.
        task["cached"] == true or task["status"] not in @finished_statuses ->
          %{acc | running: MapSet.delete(acc.running, task_id)}

        MapSet.member?(acc.finished, task_id) ->
          %{acc | running: MapSet.delete(acc.running, task_id)}

        true ->
          IO.puts("[coordinator] Task #{task_id} #{snapshot_status(task)} (replayed)")

          %{
            acc
            | finished: MapSet.put(acc.finished, task_id),
              running: MapSet.delete(acc.running, task_id),
              failed: acc.failed or task["status"] == "failed"
          }
      end
    end)
  end

  defp snapshot_status(%{"status" => "done"}), do: "OK"
  defp snapshot_status(%{"status" => "skipped"}), do: "SKIPPED"
  defp snapshot_status(%{"exit_code" => code}) when is_integer(code), do: "FAIL(#{code})"
  defp snapshot_status(_task), do: "FAIL"

  defp print_completion(payload) do
    IO.puts("[coordinator] Run #{payload["run_id"]} complete: #{payload["status"]}")

    case payload["summary"] do
      %{"tasks" => tasks, "counts" => counts} = summary when is_list(tasks) and is_map(counts) ->
        IO.puts(format_summary(summary))

      _ ->
        :ok
    end
  end

  # A run with no deadline never ends "unfinished" as a gate would: a
  # cancelled cd-release/cd-deploy run with tasks left is a failure.
  defp finish_with(%{"result" => "unfinished"} = result, %{managed: false} = state) do
    Result.write(state.result_file, %{result | "result" => "failed"})
    {:stop, {:shutdown, :failed}, state}
  end

  defp finish_with(result, state) do
    Result.write(state.result_file, result)

    if result["result"] == "unfinished" do
      IO.puts(
        "[dispatcher:#{state.session_id}] Unfinished at the deadline: " <>
          Result.left_line(result)
      )
    end

    {:stop, Result.stop_reason(result), state}
  end

  # A run_complete with no verdict: an older coordinator, or a session another
  # caller finished. A deadline run asks the coordinator for its verdict.
  defp finish_without_result(_status, %{managed: true} = state),
    do: read_result(state, {:shutdown, :failed})

  defp finish_without_result("complete", state), do: {:stop, :normal, state}
  defp finish_without_result(_status, state), do: {:stop, {:shutdown, :failed}, state}

  defp read_result(state, otherwise) do
    case fetch_result(state) do
      {:ok, result} ->
        finish_with(result, state)

      {:none, why} ->
        IO.puts(
          "[dispatcher:#{state.session_id}] No result for run #{state.run_id} (#{inspect(why)})"
        )

        {:stop, otherwise, state}
    end
  end

  # The verdict of this dispatcher's own run, or why there is none yet.
  defp fetch_result(%{coordinator_run_id: run_id} = state) when is_binary(run_id) do
    with {:ok, %{"run" => %{"id" => ^run_id, "result" => raw}}} <-
           state.read_run.(state.coordinator_url, state.token, state.session_id),
         {:ok, result} <- Result.parse(raw) do
      {:ok, result}
    else
      other -> {:none, other}
    end
  end

  defp fetch_result(_state), do: {:none, :no_run_id}

  # `:once` is a read after a rejoin; `:again` is the backstop timer, which
  # asks again until the run has a verdict.
  defp poll_verdict(%{coordinator_run_id: nil} = state, _mode),
    do: {:noreply, state, state.timeout_ms}

  defp poll_verdict(state, mode) do
    case fetch_result(state) do
      {:ok, result} ->
        finish_with(result, state)

      {:none, _why} ->
        if mode == :again, do: Process.send_after(self(), :read_verdict, @verdict_retry_ms)
        {:noreply, state, state.timeout_ms}
    end
  end

  # The run's deadline passed before it could start: nothing was submitted,
  # every task is left, and an unfinished gate is not a failed one.
  defp unfinished_at_start(%{tasks: tasks} = state) do
    count = length(tasks)

    finish_with(
      %{
        "result" => "unfinished",
        "total" => count,
        "cached" => 0,
        "left" => count,
        "failed" => 0,
        "failed_tasks" => []
      },
      state
    )
  end

  defp schedule_verdict_backstop(%{managed: false}), do: :ok

  defp schedule_verdict_backstop(state) do
    Process.send_after(
      self(),
      :read_verdict,
      Deadline.verdict_backstop_ms(
        state.deadline,
        state.hard_stop_after_ms,
        state.verdict_grace_ms,
        DateTime.utc_now()
      )
    )
  end

  defp submit_graph(%{tasks: tasks} = state) do
    IO.puts("[dispatcher:#{state.session_id}] Connected, submitting task graph...")

    resolved_tasks = tasks |> resolve_requirements() |> Enum.map(&wire_task/1)

    payload = %{
      "run_id" => state.run_id,
      "session_id" => state.session_id,
      "tasks" => resolved_tasks,
      "shard_config" => state.shard_config || %{}
    }

    payload =
      case state.failure_strategy do
        nil -> payload
        strategy -> Map.put(payload, "failure_strategy", strategy)
      end

    payload =
      if state.managed do
        hard_stop =
          state.deadline
          |> DateTime.add(state.hard_stop_after_ms, :millisecond)
          |> DateTime.truncate(:second)

        Map.merge(payload, %{
          "deadline_at" => state.deadline |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
          "hard_stop_at" => DateTime.to_iso8601(hard_stop)
        })
      else
        payload
      end

    reply =
      DxCore.Agents.WsClient.push_and_wait(state.client, "submit_graph", payload)

    case reply do
      {:ok, info} ->
        IO.puts(
          "[dispatcher:#{state.session_id}] Run #{state.run_id} submitted: #{info["total_tasks"]} tasks (#{info["cached_tasks"]} cached)"
        )

        # From now on every rejoin asks for this run, which the coordinator
        # then replays; it refuses the rejoin if it has no such run.
        DxCore.Agents.WsClient.set_join_params(state.client, %{"resume" => true})
        state = %{state | tasks: nil, coordinator_run_id: info["run_id"]}

        if state.managed and not is_binary(info["deadline_at"]) do
          IO.puts(
            "[dispatcher:#{state.session_id}] The coordinator did not take the deadline " <>
              "(it is older than this CLI); cancelling the run"
          )

          push_with_reply(state, "cancel_run")
          {:stop, {:shutdown, :deadline_unsupported}, state}
        else
          schedule_verdict_backstop(state)
          {:noreply, state, state.timeout_ms}
        end

      # Only a deadline already past is a late start; "more than 60 minutes
      # ahead" is a bad --deadline and fails. The message text is owned by
      # DxCore.SaaS.RunDeadlines in the coordinator.
      {:error,
       %{"reason" => "invalid_deadline", "field" => "deadline_at", "message" => "is in the past"}}
      when state.managed ->
        IO.puts(
          "[dispatcher:#{state.session_id}] The coordinator says the deadline has passed; nothing was submitted"
        )

        unfinished_at_start(state)

      {:error, reason} ->
        IO.puts("[dispatcher:#{state.session_id}] Failed to submit graph: #{inspect(reason)}")

        {:stop, {:shutdown, :submit_failed}, state}
    end
  end

  # The coordinator's reply within 10 seconds, or why there is none. A
  # GenServer.call timeout exits the caller, which would turn an unfinished
  # run into a crash (exit 1).
  defp push_with_reply(state, event) do
    DxCore.Agents.WsClient.push_and_wait(
      state.client,
      event,
      %{"run_id" => state.coordinator_run_id},
      10_000
    )
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  # The fields the coordinator builds its graph from (`DxCore.Core.TaskGraph`
  # `parse_task/1`, kept equal by dispatcher_test.exs). A build system's task
  # carries much more: a turbo dry-run task holds every input file's hash, its
  # env vars and its resolved definition, about 11 KB a task, which on an
  # 800-task graph OOM-killed the coordinator.
  @wire_fields ~w(taskId task package hash command dependencies dependents cache cacheable shard requirements)

  @doc "Keeps only the fields of a task the coordinator reads."
  def wire_task(task) when is_map(task), do: Map.take(task, @wire_fields)

  @doc false
  def wire_fields, do: @wire_fields

  @doc """
  Resolves dxcore requirements from each task's package.json.

  For each task, reads `package.json` from the task's `directory` field,
  extracts `dxcore.requirements`, and matches by exact task name or `*` fallback.
  Attaches the resolved `requirements` map to each task.
  """
  def resolve_requirements(tasks) do
    Enum.map(tasks, fn
      # A graph built off the checkout (ci.yml's plan job, #15513) carries
      # each task's requirements; there is no package.json to read here.
      %{"requirements" => reqs} = task when is_map(reqs) and not is_map_key(task, "directory") ->
        task

      task ->
        Map.put(task, "requirements", resolve_task_requirements(task))
    end)
  end

  defp resolve_task_requirements(%{"directory" => dir, "task" => task_name})
       when is_binary(dir) do
    package_json_path = Path.join(dir, "package.json")

    case File.read(package_json_path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, %{"dxcore" => %{"requirements" => reqs}}} when is_map(reqs) ->
            Map.get(reqs, task_name, Map.get(reqs, "*", %{}))

          _ ->
            %{}
        end

      {:error, _} ->
        %{}
    end
  end

  defp resolve_task_requirements(_), do: %{}

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
    rows =
      Enum.map(tasks, fn t ->
        {t["task_id"], t["agent_id"] || "—", format_task_status(t),
         format_duration(t["duration_ms"])}
      end)

    {id_width, agent_width, status_width, dur_width} =
      Enum.reduce(rows, {0, 0, 0, 0}, fn {id, a, s, d}, {iw, aw, sw, dw} ->
        {max(iw, String.length(id)), max(aw, String.length(a)), max(sw, String.length(s)),
         max(dw, String.length(d))}
      end)

    rows
    |> Enum.map(fn {id, agent, status, duration} ->
      " #{String.pad_trailing(id, id_width)}  #{String.pad_trailing(agent, agent_width)}  #{String.pad_trailing(status, status_width)}  #{String.pad_leading(duration, dur_width)}"
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
          failure_strategy: :string,
          deadline: :string,
          hard_stop_after: :string,
          result_file: :string
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
