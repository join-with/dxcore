defmodule DxCore.Core.TaskLogBuffer do
  @moduledoc """
  ETS-based buffer for task log lines, used to build run summaries.

  A run that completes calls `cleanup/2` to drop its buffered lines. Runs that
  never reach a terminal status (abandoned agents, dropped sockets) would
  otherwise leak their lines forever, so the owning GenServer periodically
  `sweep/2`s rows older than `:ttl_ms`. See issue #4382.
  """
  use GenServer

  require Logger

  @default_ttl_ms :timer.hours(2)
  @default_sweep_interval_ms :timer.minutes(5)

  def start_link(opts) do
    table_name = Keyword.fetch!(opts, :table_name)
    name = Keyword.get(opts, :name, __MODULE__)
    ttl_ms = Keyword.get(opts, :ttl_ms, @default_ttl_ms)
    sweep_interval_ms = Keyword.get(opts, :sweep_interval_ms, @default_sweep_interval_ms)

    GenServer.start_link(__MODULE__, {table_name, ttl_ms, sweep_interval_ms}, name: name)
  end

  def buffer(table, session_id, task_id, line) do
    :ets.insert(table, {{session_id, task_id}, line, System.monotonic_time()})
  end

  def get_output(table, session_id, task_id) do
    table
    |> :ets.match_object({{session_id, task_id}, :"$1", :"$2"})
    |> Enum.sort_by(fn {_key, _line, ts} -> ts end)
    |> Enum.map(fn {_key, line, _ts} -> line end)
    |> Enum.join("\n")
  end

  def cleanup(table, session_id) do
    :ets.match_delete(table, {{session_id, :_}, :_, :_})
  end

  @doc """
  Deletes every row whose stored monotonic timestamp is strictly older than
  `cutoff` (a `System.monotonic_time()` value). Returns the number of rows
  deleted. Used by the periodic TTL sweep to reclaim log lines from runs that
  never reached a terminal status (and so never hit `cleanup/2`).
  """
  def sweep(table, cutoff) do
    :ets.select_delete(table, [{{:_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])
  end

  @impl true
  def init({table_name, ttl_ms, sweep_interval_ms}) do
    table = :ets.new(table_name, [:named_table, :public, :duplicate_bag])
    schedule_sweep(sweep_interval_ms)
    {:ok, %{table: table, ttl_ms: ttl_ms, sweep_interval_ms: sweep_interval_ms}}
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
  defp run_sweep(%{table: table, ttl_ms: ttl_ms}) do
    cutoff = System.monotonic_time() - System.convert_time_unit(ttl_ms, :millisecond, :native)
    deleted = sweep(table, cutoff)

    :telemetry.execute(
      [:dxcore, :task_log_buffer, :sweep],
      %{
        deleted: deleted,
        remaining: :ets.info(table, :size),
        memory_words: :ets.info(table, :memory)
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

  defp schedule_sweep(interval_ms) do
    Process.send_after(self(), :sweep, interval_ms)
  end
end
