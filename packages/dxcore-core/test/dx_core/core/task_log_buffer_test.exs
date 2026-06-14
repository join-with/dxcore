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

  describe "buffer/4 and get_output/3" do
    test "buffers and retrieves log lines in order", %{table: table} do
      TaskLogBuffer.buffer(table, "session-1", "task-1", "line 1")
      TaskLogBuffer.buffer(table, "session-1", "task-1", "line 2")
      TaskLogBuffer.buffer(table, "session-1", "task-1", "line 3")

      output = TaskLogBuffer.get_output(table, "session-1", "task-1")
      assert output == "line 1\nline 2\nline 3"
    end

    test "isolates by session and task", %{table: table} do
      TaskLogBuffer.buffer(table, "session-1", "task-1", "s1-t1")
      TaskLogBuffer.buffer(table, "session-1", "task-2", "s1-t2")
      TaskLogBuffer.buffer(table, "session-2", "task-1", "s2-t1")

      assert TaskLogBuffer.get_output(table, "session-1", "task-1") == "s1-t1"
      assert TaskLogBuffer.get_output(table, "session-1", "task-2") == "s1-t2"
      assert TaskLogBuffer.get_output(table, "session-2", "task-1") == "s2-t1"
    end

    test "returns empty string when no logs exist", %{table: table} do
      assert TaskLogBuffer.get_output(table, "no-session", "no-task") == ""
    end
  end

  describe "cleanup/2" do
    test "removes all logs for a session", %{table: table} do
      TaskLogBuffer.buffer(table, "session-1", "task-1", "line 1")
      TaskLogBuffer.buffer(table, "session-1", "task-2", "line 2")
      TaskLogBuffer.buffer(table, "session-2", "task-1", "other")

      TaskLogBuffer.cleanup(table, "session-1")

      assert TaskLogBuffer.get_output(table, "session-1", "task-1") == ""
      assert TaskLogBuffer.get_output(table, "session-1", "task-2") == ""
      assert TaskLogBuffer.get_output(table, "session-2", "task-1") == "other"
    end
  end

  describe "sweep/2" do
    test "deletes rows older than cutoff and keeps newer rows", %{table: table} do
      old_ts = System.monotonic_time() - System.convert_time_unit(10, :second, :native)
      new_ts = System.monotonic_time()

      # Insert raw rows with controlled timestamps (bypassing buffer/4's clock).
      :ets.insert(table, {{"session-1", "task-1"}, "old line", old_ts})
      :ets.insert(table, {{"session-1", "task-1"}, "new line", new_ts})

      cutoff = System.monotonic_time() - System.convert_time_unit(5, :second, :native)

      assert TaskLogBuffer.sweep(table, cutoff) == 1
      assert TaskLogBuffer.get_output(table, "session-1", "task-1") == "new line"
    end

    test "returns 0 and deletes nothing when all rows are newer than cutoff", %{table: table} do
      TaskLogBuffer.buffer(table, "session-1", "task-1", "fresh")
      cutoff = System.monotonic_time() - System.convert_time_unit(3600, :second, :native)

      assert TaskLogBuffer.sweep(table, cutoff) == 0
      assert TaskLogBuffer.get_output(table, "session-1", "task-1") == "fresh"
    end
  end

  describe "periodic sweep (GenServer)" do
    test "removes aged rows automatically on its interval" do
      table_name = :"sweep_tbl_#{System.unique_integer([:positive])}"

      start_supervised!(
        {TaskLogBuffer,
         table_name: table_name,
         name: :"sweep_srv_#{System.unique_integer([:positive])}",
         ttl_ms: 1,
         sweep_interval_ms: 10}
      )

      TaskLogBuffer.buffer(table_name, "session-1", "task-1", "ephemeral")
      assert TaskLogBuffer.get_output(table_name, "session-1", "task-1") == "ephemeral"

      # First sweep fires at ~10ms; the row (ttl 1ms) is past TTL by then.
      Process.sleep(60)
      assert TaskLogBuffer.get_output(table_name, "session-1", "task-1") == ""
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

      TaskLogBuffer.buffer(table_name, "session-1", "task-1", "x")

      assert_receive {:sweep_telemetry, measurements}, 500
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

      assert_receive {:sweep_error, %{count: 1}}, 500
      assert_receive {:sweep_error, %{count: 1}}, 500
    end
  end
end
