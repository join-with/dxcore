defmodule DxCore.Core.TaskLogBuffer do
  @moduledoc """
  ETS-based buffer for task log lines, used to build run summaries.

  Lines are keyed `{session_id, run_id, task_id}`. One session can hold
  several runs at once (e.g. the dispatch jobs of one CI workflow run), and
  they can run the same task ids, so every read and delete is per run.

  A line whose run is unknown (`run_id` nil, e.g. a line that reached a
  channel with no recorded assignment after a reconnect) is kept under
  `{session_id, nil, task_id}`. `get_output/4` returns those lines with the
  run's own, in arrival order; `delete_task/4` and `cleanup/3` leave them,
  since they cannot tell which run they belong to, and the TTL sweep
  reclaims them.

  Only a failed task's output is ever read (it goes into the run summary's
  failure details), so callers drop a task's lines with `delete_task/4` once
  its success is accepted. A run that completes calls `cleanup/3` to drop the
  rest of its lines. Runs that never reach a terminal status (abandoned
  agents, dropped sockets, a dispatcher timeout) would otherwise keep their
  lines forever, so the owning GenServer periodically `sweep/2`s rows older
  than `:ttl_ms` (#4382).

  ## Memory accounting and the cap

  A line decoded from a WebSocket frame is a sub-binary of that frame, and ETS
  keeps a sub-binary over 64 bytes as a reference, so storing it as-is would
  keep the whole frame alive outside the table. `buffer/5` stores a copy.
  A copied line over 64 bytes still lives off-heap, where
  `:ets.info(table, :memory)` does not see it, so each row records its
  off-heap size and a table started by `start_link/1` keeps a running total.
  `memory_bytes/1` is the table's real footprint: ETS words (rows and the
  per-task drop counts) plus that total.

  Tables started by `start_link/1` have a hard cap (`:max_bytes`, default
  128 MiB) on `memory_bytes/1`. At the cap `buffer/5` drops the line and counts
  it against its task; `get_output/4` then ends that task's output with
  `"[dxcore: N log lines dropped, buffer full]"`. The next sweep logs the
  number dropped and reports it in its telemetry (#11028).

  The running total is adjusted on every insert and delete, and the sweep
  recomputes it from the rows, so it cannot drift for longer than one sweep.
  """
  use GenServer

  require Logger

  @default_ttl_ms :timer.hours(2)
  @default_sweep_interval_ms :timer.minutes(5)
  @default_max_bytes 128 * 1024 * 1024

  # ETS stores a binary of up to 64 bytes inside the row (so it is counted in
  # `:ets.info(table, :memory)`) and a larger one off-heap.
  @heap_binary_limit 64

  # Distinct tasks that can carry a "lines dropped" marker (about 150 bytes
  # each). A run has about a thousand tasks.
  @max_drop_entries 10_000

  def start_link(opts) do
    table_name = Keyword.fetch!(opts, :table_name)
    name = Keyword.get(opts, :name, __MODULE__)
    ttl_ms = Keyword.get(opts, :ttl_ms, @default_ttl_ms)
    sweep_interval_ms = Keyword.get(opts, :sweep_interval_ms, @default_sweep_interval_ms)
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)

    unless is_integer(max_bytes) and max_bytes > 0 do
      raise ArgumentError,
            "TaskLogBuffer :max_bytes must be a positive integer, got: #{inspect(max_bytes)}"
    end

    GenServer.start_link(
      __MODULE__,
      {table_name, ttl_ms, sweep_interval_ms, max_bytes},
      name: name
    )
  end

  @doc """
  Stores one log line for `{session_id, run_id, task_id}`; `run_id` is nil
  when the caller does not know the run. Returns `true` when the line
  was stored and `false` when the table is at its `:max_bytes` cap and the line
  was dropped. A table not created by `start_link/1` has no cap.
  """
  def buffer(table, session_id, run_id, task_id, line) when is_binary(line) do
    key = {session_id, run_id, task_id}

    case config(table) do
      nil ->
        insert(table, nil, key, line)

      cfg ->
        if memory_bytes(table, cfg) >= cfg.max_bytes do
          record_drop(cfg, key)
          false
        else
          insert(table, cfg, key, line)
        end
    end
  end

  # Agents only send strings; anything else is not stored.
  def buffer(_table, _session_id, _run_id, _task_id, _line), do: false

  defp insert(table, cfg, key, line) do
    line = :binary.copy(line)
    off_heap = off_heap_bytes(line)
    :ets.insert(table, {key, line, System.monotonic_time(), off_heap})
    if cfg && off_heap > 0, do: :counters.add(cfg.off_heap, 1, off_heap)
    true
  end

  defp off_heap_bytes(line) when byte_size(line) > @heap_binary_limit, do: byte_size(line)
  defp off_heap_bytes(_line), do: 0

  # The per-task drop counts are bounded too: past @max_drop_entries tasks,
  # a drop is only counted in the sweep's total.
  defp record_drop(cfg, key) do
    :counters.add(cfg.dropped, 1, 1)

    if :ets.member(cfg.drops, key) or :ets.info(cfg.drops, :size) < @max_drop_entries do
      :ets.update_counter(cfg.drops, key, {2, 1}, {key, 0, System.monotonic_time()})
    end
  end

  @doc """
  The table's real memory in bytes: its ETS words plus the off-heap bytes of
  the lines it holds. For a table not created by `start_link/1`, ETS only.
  """
  def memory_bytes(table), do: memory_bytes(table, config(table))

  defp memory_bytes(table, nil), do: :ets.info(table, :memory) * :erlang.system_info(:wordsize)

  defp memory_bytes(table, cfg) do
    words = :ets.info(table, :memory) + :ets.info(cfg.drops, :memory)
    words * :erlang.system_info(:wordsize) + :counters.get(cfg.off_heap, 1)
  end

  @doc """
  The run's buffered output for one task, plus any lines buffered for that
  task with no known run, in arrival order. Ends with a
  `"[dxcore: N log lines dropped, buffer full]"` line when lines were dropped
  at the cap.
  """
  def get_output(table, session_id, run_id, task_id) do
    keys = Enum.uniq([{session_id, run_id, task_id}, {session_id, nil, task_id}])

    lines =
      keys
      |> Enum.flat_map(&:ets.lookup(table, &1))
      |> Enum.sort_by(fn {_key, _line, ts, _off_heap} -> ts end)
      |> Enum.map(fn {_key, line, _ts, _off_heap} -> line end)

    lines
    |> Kernel.++(drop_marker(table, keys))
    |> Enum.join("\n")
  end

  defp drop_marker(table, keys) do
    with %{drops: drops} <- config(table),
         dropped when dropped > 0 <- keys |> Enum.map(&dropped_for(drops, &1)) |> Enum.sum() do
      ["[dxcore: #{dropped} log lines dropped, buffer full]"]
    else
      _ -> []
    end
  end

  defp dropped_for(drops, key) do
    case :ets.lookup(drops, key) do
      [{^key, dropped, _ts}] -> dropped
      [] -> 0
    end
  end

  @doc """
  Drops every buffered line of one run's task, e.g. once its success is
  accepted. Lines of the same task id in other runs, and run-less lines, stay.
  """
  def delete_task(table, session_id, run_id, task_id) do
    key = {session_id, run_id, task_id}
    delete_where(table, [{{key, :_, :_, :"$1"}, [], [:"$1"]}], fn -> :ets.delete(table, key) end)

    with %{drops: drops} <- config(table), do: :ets.delete(drops, key)
    true
  end

  @doc """
  Drops every buffered line of one run, e.g. once it completes. Other runs in
  the same session, and run-less lines, stay.
  """
  def cleanup(table, session_id, run_id) do
    delete_where(table, [{{{session_id, run_id, :_}, :_, :_, :"$1"}, [], [:"$1"]}], fn ->
      :ets.match_delete(table, {{session_id, run_id, :_}, :_, :_, :_})
    end)

    with %{drops: drops} <- config(table),
         do: :ets.match_delete(drops, {{session_id, run_id, :_}, :_, :_})

    true
  end

  # Subtracts the off-heap bytes of the rows `size_spec` selects, then runs
  # `delete`. A row inserted between the two is deleted uncounted; the next
  # sweep's recount corrects that.
  defp delete_where(table, size_spec, delete) do
    case config(table) do
      nil ->
        delete.()

      cfg ->
        freed = table |> :ets.select(size_spec) |> Enum.sum()
        delete.()
        :counters.sub(cfg.off_heap, 1, freed)
    end
  end

  @doc """
  Deletes every row whose stored monotonic timestamp is strictly older than
  `cutoff` (a `System.monotonic_time()` value). Returns the number of rows
  deleted. Used by the periodic TTL sweep to reclaim log lines from runs that
  never reached a terminal status (and so never hit `cleanup/3`).
  """
  def sweep(table, cutoff) do
    deleted = :ets.select_delete(table, [{{:_, :_, :"$1", :_}, [{:<, :"$1", cutoff}], [true]}])

    with %{drops: drops} = cfg <- config(table) do
      :ets.select_delete(drops, [{{:_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])
      recount_off_heap(table, cfg)
    end

    deleted
  end

  defp recount_off_heap(table, cfg) do
    total = table |> :ets.select([{{:_, :_, :_, :"$1"}, [{:>, :"$1", 0}], [:"$1"]}]) |> Enum.sum()
    :counters.put(cfg.off_heap, 1, total)
  end

  defp config(table), do: :persistent_term.get({__MODULE__, table}, nil)

  @impl true
  def init({table_name, ttl_ms, sweep_interval_ms, max_bytes}) do
    table = :ets.new(table_name, [:named_table, :public, :duplicate_bag])

    cfg = %{
      max_bytes: max_bytes,
      off_heap: :counters.new(1, [:write_concurrency]),
      dropped: :counters.new(1, [:write_concurrency]),
      drops: :ets.new(:task_log_buffer_drops, [:set, :public, write_concurrency: true])
    }

    :persistent_term.put({__MODULE__, table}, cfg)
    schedule_sweep(sweep_interval_ms)

    {:ok,
     %{
       table: table,
       ttl_ms: ttl_ms,
       sweep_interval_ms: sweep_interval_ms,
       max_bytes: max_bytes,
       dropped: cfg.dropped
     }}
  end

  @impl true
  def handle_info(:sweep, state) do
    run_sweep(state)
    schedule_sweep(state.sweep_interval_ms)
    {:noreply, state}
  end

  # Best-effort: a failing sweep must never crash the table-owning process,
  # which would drop the entire buffer and restart. Log + emit telemetry and
  # let `handle_info` reschedule the next tick regardless.
  defp run_sweep(%{table: table, ttl_ms: ttl_ms} = state) do
    cutoff = System.monotonic_time() - System.convert_time_unit(ttl_ms, :millisecond, :native)
    deleted = sweep(table, cutoff)
    dropped = take_dropped(state.dropped)
    memory_bytes = memory_bytes(table)

    if dropped > 0 do
      Logger.warning(
        "TaskLogBuffer #{inspect(table)} is at its #{state.max_bytes}-byte cap: " <>
          "dropped #{dropped} log lines since the last sweep (table now #{memory_bytes} bytes)"
      )
    end

    :telemetry.execute(
      [:dxcore, :task_log_buffer, :sweep],
      %{
        deleted: deleted,
        dropped: dropped,
        remaining: :ets.info(table, :size),
        memory_words: :ets.info(table, :memory),
        memory_bytes: memory_bytes
      },
      %{table: table}
    )
  rescue
    error ->
      Logger.error("TaskLogBuffer sweep failed: #{inspect(error)}")

      :telemetry.execute(
        [:dxcore, :task_log_buffer, :sweep_error],
        %{count: 1},
        %{table: table, error: inspect(error)}
      )
  end

  # Reads and zeroes the dropped-lines counter. A line dropped between the get
  # and the sub stays counted for the next sweep.
  defp take_dropped(counter) do
    dropped = :counters.get(counter, 1)
    :counters.sub(counter, 1, dropped)
    dropped
  end

  defp schedule_sweep(interval_ms) do
    Process.send_after(self(), :sweep, interval_ms)
  end
end
