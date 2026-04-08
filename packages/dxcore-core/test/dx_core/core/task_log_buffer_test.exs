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
end
