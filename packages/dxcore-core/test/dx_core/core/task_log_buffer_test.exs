defmodule DxCore.Core.TaskLogBufferTest do
  use ExUnit.Case, async: true

  alias DxCore.Core.TaskLogBuffer

  setup do
    table =
      :ets.new(:"test_log_buffer_#{System.unique_integer([:positive])}", [
        :named_table,
        :public,
        :duplicate_bag
      ])

    %{table: table}
  end

  describe "buffer/5 and get_output/4" do
    test "buffers and retrieves log lines in order", %{table: table} do
      TaskLogBuffer.buffer(table, "session-1", "run-1", "task-1", "line 1")
      TaskLogBuffer.buffer(table, "session-1", "run-1", "task-1", "line 2")
      TaskLogBuffer.buffer(table, "session-1", "run-1", "task-1", "line 3")

      output = TaskLogBuffer.get_output(table, "session-1", "run-1", "task-1")
      assert output == "line 1\nline 2\nline 3"
    end

    test "isolates by session and task", %{table: table} do
      TaskLogBuffer.buffer(table, "session-1", "run-1", "task-1", "s1-t1")
      TaskLogBuffer.buffer(table, "session-1", "run-1", "task-2", "s1-t2")
      TaskLogBuffer.buffer(table, "session-2", "run-1", "task-1", "s2-t1")

      assert TaskLogBuffer.get_output(table, "session-1", "run-1", "task-1") == "s1-t1"
      assert TaskLogBuffer.get_output(table, "session-1", "run-1", "task-2") == "s1-t2"
      assert TaskLogBuffer.get_output(table, "session-2", "run-1", "task-1") == "s2-t1"
    end

    test "returns empty string when no logs exist", %{table: table} do
      assert TaskLogBuffer.get_output(table, "no-session", "run-1", "no-task") == ""
    end
  end

  describe "cleanup/3" do
    test "removes all logs for a run", %{table: table} do
      TaskLogBuffer.buffer(table, "session-1", "run-1", "task-1", "line 1")
      TaskLogBuffer.buffer(table, "session-1", "run-1", "task-2", "line 2")
      TaskLogBuffer.buffer(table, "session-2", "run-1", "task-1", "other")

      TaskLogBuffer.cleanup(table, "session-1", "run-1")

      assert TaskLogBuffer.get_output(table, "session-1", "run-1", "task-1") == ""
      assert TaskLogBuffer.get_output(table, "session-1", "run-1", "task-2") == ""
      assert TaskLogBuffer.get_output(table, "session-2", "run-1", "task-1") == "other"
    end
  end

  describe "delete_task/4" do
    test "drops one task's lines and keeps every other task's", %{table: table} do
      TaskLogBuffer.buffer(table, "session-1", "run-1", "task-1", "a")
      TaskLogBuffer.buffer(table, "session-1", "run-1", "task-1", "b")
      TaskLogBuffer.buffer(table, "session-1", "run-1", "task-2", "keep")
      TaskLogBuffer.buffer(table, "session-2", "run-1", "task-1", "other session")

      TaskLogBuffer.delete_task(table, "session-1", "run-1", "task-1")

      assert TaskLogBuffer.get_output(table, "session-1", "run-1", "task-1") == ""
      assert TaskLogBuffer.get_output(table, "session-1", "run-1", "task-2") == "keep"
      assert TaskLogBuffer.get_output(table, "session-2", "run-1", "task-1") == "other session"
    end
  end

  describe "runs sharing a session" do
    test "deleting one run's task leaves the same task id in another run", %{table: table} do
      TaskLogBuffer.buffer(table, "session-1", "run-a", "@repo/ui#build", "A failed")
      TaskLogBuffer.buffer(table, "session-1", "run-b", "@repo/ui#build", "B passed")

      TaskLogBuffer.delete_task(table, "session-1", "run-b", "@repo/ui#build")

      assert TaskLogBuffer.get_output(table, "session-1", "run-a", "@repo/ui#build") ==
               "A failed"

      assert TaskLogBuffer.get_output(table, "session-1", "run-b", "@repo/ui#build") == ""
    end

    test "cleaning up one run leaves the other runs of the session", %{table: table} do
      TaskLogBuffer.buffer(table, "session-1", "run-a", "@repo/ui#build", "A line")
      TaskLogBuffer.buffer(table, "session-1", "run-b", "@repo/ui#build", "B line")
      TaskLogBuffer.buffer(table, "session-1", "run-b", "@repo/api#test", "B other")

      TaskLogBuffer.cleanup(table, "session-1", "run-a")

      assert TaskLogBuffer.get_output(table, "session-1", "run-a", "@repo/ui#build") == ""
      assert TaskLogBuffer.get_output(table, "session-1", "run-b", "@repo/ui#build") == "B line"
      assert TaskLogBuffer.get_output(table, "session-1", "run-b", "@repo/api#test") == "B other"
    end

    test "run-less lines are read with the run's own and outlive its deletes", %{table: table} do
      TaskLogBuffer.buffer(table, "session-1", "run-a", "t", "first")
      TaskLogBuffer.buffer(table, "session-1", nil, "t", "after a reconnect")
      TaskLogBuffer.buffer(table, "session-1", "run-a", "t", "last")

      assert TaskLogBuffer.get_output(table, "session-1", "run-a", "t") ==
               "first\nafter a reconnect\nlast"

      TaskLogBuffer.delete_task(table, "session-1", "run-a", "t")
      TaskLogBuffer.cleanup(table, "session-1", "run-a")
      assert TaskLogBuffer.get_output(table, "session-1", "run-b", "t") == "after a reconnect"
    end
  end

  describe ":max_bytes cap" do
    test "drops lines once the table reaches its cap and reports them on the next sweep" do
      handler_id = "cap-tel-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:dxcore, :task_log_buffer, :sweep],
        fn _event, measurements, _meta, _config ->
          send(test_pid, {:sweep_telemetry, measurements})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      table_name = :"cap_tbl_#{System.unique_integer([:positive])}"

      # The sweep is triggered by hand below, so it can't run before the log is
      # captured.
      buffer_pid =
        start_supervised!(
          {TaskLogBuffer,
           table_name: table_name,
           name: :"cap_srv_#{System.unique_integer([:positive])}",
           max_bytes: 64 * 1024,
           sweep_interval_ms: :timer.hours(1)}
        )

      line = String.duplicate("x", 200)

      results =
        for i <- 1..2_000,
            do: TaskLogBuffer.buffer(table_name, "s", "run-1", "t#{rem(i, 10)}", line)

      stored = Enum.count(results, & &1)
      dropped = Enum.count(results, &(!&1))

      assert stored > 0
      assert dropped > 0
      # The cap is checked before each insert, so the table stops one row (plus
      # the hash table's own bucket growth) past it, not at the 2,000 rows.
      assert TaskLogBuffer.memory_bytes(table_name) < 64 * 1024 * 1.25

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          send(buffer_pid, :sweep)
          assert_receive {:sweep_telemetry, %{dropped: ^dropped, memory_bytes: bytes}}, 5_000
          assert bytes > 64 * 1024 and bytes < 64 * 1024 * 1.25
          # Let the sweep finish logging before capture_log returns.
          Process.sleep(20)
        end)

      assert log =~ "dropped #{dropped} log lines"
    end

    test "a table with no cap configured keeps every line", %{table: table} do
      for i <- 1..500, do: assert(TaskLogBuffer.buffer(table, "s", "run-1", "t", "line #{i}"))
      assert :ets.info(table, :size) == 500
    end

    test "rejects a non-positive :max_bytes at start" do
      assert_raise ArgumentError, ~r/:max_bytes must be a positive integer/, fn ->
        TaskLogBuffer.start_link(table_name: :never_created, name: :never_started, max_bytes: 0)
      end
    end
  end

  describe "sweep/2" do
    test "deletes rows older than cutoff and keeps newer rows", %{table: table} do
      old_ts = System.monotonic_time() - System.convert_time_unit(10, :second, :native)
      new_ts = System.monotonic_time()

      # Insert raw rows with controlled timestamps (bypassing buffer/5's clock).
      :ets.insert(table, {{"session-1", "run-1", "task-1"}, "old line", old_ts, 0})
      :ets.insert(table, {{"session-1", "run-1", "task-1"}, "new line", new_ts, 0})

      cutoff = System.monotonic_time() - System.convert_time_unit(5, :second, :native)

      assert TaskLogBuffer.sweep(table, cutoff) == 1
      assert TaskLogBuffer.get_output(table, "session-1", "run-1", "task-1") == "new line"
    end

    test "returns 0 and deletes nothing when all rows are newer than cutoff", %{table: table} do
      TaskLogBuffer.buffer(table, "session-1", "run-1", "task-1", "fresh")
      cutoff = System.monotonic_time() - System.convert_time_unit(3600, :second, :native)

      assert TaskLogBuffer.sweep(table, cutoff) == 0
      assert TaskLogBuffer.get_output(table, "session-1", "run-1", "task-1") == "fresh"
    end
  end

  describe "periodic sweep (GenServer)" do
    test "removes aged rows automatically on its interval" do
      table_name = :"sweep_tbl_#{System.unique_integer([:positive])}"

      start_supervised!(
        {TaskLogBuffer,
         table_name: table_name,
         name: :"sweep_srv_#{System.unique_integer([:positive])}",
         ttl_ms: 200,
         sweep_interval_ms: 10}
      )

      TaskLogBuffer.buffer(table_name, "session-1", "run-1", "task-1", "ephemeral")
      assert TaskLogBuffer.get_output(table_name, "session-1", "run-1", "task-1") == "ephemeral"

      # A sweep every 10ms removes the row once it is past its 200ms TTL.
      assert eventually(fn ->
               TaskLogBuffer.get_output(table_name, "session-1", "run-1", "task-1") == ""
             end)
    end

    test "emits [:dxcore, :task_log_buffer, :sweep] telemetry with measurements" do
      handler_id = "sweep-tel-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:dxcore, :task_log_buffer, :sweep],
        fn _event, measurements, _meta, _config ->
          send(test_pid, {:sweep_telemetry, measurements})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      table_name = :"tel_tbl_#{System.unique_integer([:positive])}"

      start_supervised!(
        {TaskLogBuffer,
         table_name: table_name,
         name: :"tel_srv_#{System.unique_integer([:positive])}",
         ttl_ms: 1,
         sweep_interval_ms: 10}
      )

      TaskLogBuffer.buffer(table_name, "session-1", "run-1", "task-1", "x")

      assert_receive {:sweep_telemetry, measurements}, 5_000
      assert is_integer(measurements.deleted)
      assert is_integer(measurements.remaining)
      assert is_integer(measurements.memory_words)
    end

    test "survives a sweep error and reschedules (sweep_error telemetry fires repeatedly)" do
      handler_id = "sweep-err-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:dxcore, :task_log_buffer, :sweep_error],
        fn _event, measurements, _meta, _config ->
          send(test_pid, {:sweep_error, measurements})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      # A non-integer ttl_ms makes `System.convert_time_unit/3` raise on every
      # tick, standing in for any unexpected sweep failure. The rescue must
      # emit :sweep_error AND handle_info must still reschedule - so we expect
      # to receive the event more than once (proving the loop survived).
      start_supervised!(
        {TaskLogBuffer,
         table_name: :"err_tbl_#{System.unique_integer([:positive])}",
         name: :"err_srv_#{System.unique_integer([:positive])}",
         ttl_ms: :invalid,
         sweep_interval_ms: 10}
      )

      assert_receive {:sweep_error, %{count: 1}}, 5_000
      assert_receive {:sweep_error, %{count: 1}}, 5_000
    end
  end

  defp eventually(fun, deadline_ms \\ 5_000) do
    cond do
      fun.() -> true
      deadline_ms <= 0 -> false
      true -> Process.sleep(20) && eventually(fun, deadline_ms - 20)
    end
  end
end
