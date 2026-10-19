defmodule DxCore.Core.TaskLogBufferMemoryTest do
  # Measures VM-wide binary memory, so it runs alone (async: false modules run
  # after the async ones, one at a time).
  use ExUnit.Case, async: false

  alias DxCore.Core.TaskLogBuffer

  @line_bytes 4_000

  setup do
    table = :"mem_tbl_#{System.unique_integer([:positive])}"
    name = :"mem_srv_#{System.unique_integer([:positive])}"
    %{table: table, name: name}
  end

  defp start_buffer(ctx, max_bytes) do
    start_supervised!(
      {TaskLogBuffer, table_name: ctx.table, name: ctx.name, max_bytes: max_bytes}
    )
  end

  # A task_log frame as an agent sends it, decoded the way the socket's
  # serializer does (Jason's default `strings: :reference`), so the decoded
  # line is a sub-binary of the whole frame.
  defp decoded_line(line, padding \\ 0) do
    frame =
      Jason.encode!([
        "3",
        "1",
        "agent:org:session",
        "task_log",
        %{"task_id" => "t", "line" => line, "pad" => String.duplicate("p", padding)}
      ])

    [_, _, _, _, %{"line" => decoded}] = Jason.decode!(frame)
    decoded
  end

  defp distinct_line(i) do
    prefix = "#{i}:"
    prefix <> String.duplicate("x", @line_bytes - byte_size(prefix))
  end

  # Collects every process, so binaries other tests left for the GC are not
  # freed in the middle of a measurement.
  defp settled_binary_memory do
    Enum.each(Process.list(), &:erlang.garbage_collect/1)
    Process.sleep(50)
    :erlang.memory(:binary)
  end

  defp real_bytes(table, binary_before) do
    binary_after = settled_binary_memory()
    ets = (:ets.info(table, :memory) + drops_words(table)) * :erlang.system_info(:wordsize)
    ets + (binary_after - binary_before)
  end

  defp drops_words(table) do
    %{drops: drops} = :persistent_term.get({TaskLogBuffer, table})
    :ets.info(drops, :memory)
  end

  test "a stored line does not keep its whole frame alive", ctx do
    start_buffer(ctx, 16 * 1024 * 1024)
    line = decoded_line(distinct_line(1), 100_000)
    # Sanity: the decoded line really is a slice of the 100 KB frame.
    assert :binary.referenced_byte_size(line) > 100_000

    assert TaskLogBuffer.buffer(ctx.table, "s", "run-1", "t", line)
    assert [{_, stored, _, _}] = :ets.lookup(ctx.table, {"s", "run-1", "t"})
    assert :binary.referenced_byte_size(stored) == @line_bytes
  end

  test "the cap bounds the table's real memory, line bytes included", ctx do
    max_bytes = 2 * 1024 * 1024
    start_buffer(ctx, max_bytes)
    binary_before = settled_binary_memory()

    # 2,000 distinct 4 KB lines (8 MB) decoded from frames in a process that
    # then exits, so only what the buffer keeps survives.
    results =
      Task.async(fn ->
        for i <- 1..2_000 do
          TaskLogBuffer.buffer(
            ctx.table,
            "s",
            "run-1",
            "t#{rem(i, 20)}",
            decoded_line(distinct_line(i))
          )
        end
      end)
      |> Task.await()

    assert Enum.count(results, &(!&1)) > 0
    real = real_bytes(ctx.table, binary_before)
    assert real < max_bytes * 1.15, "real memory #{real} bytes is over the #{max_bytes} cap"
    # The buffer's own figure (what the sweep reports) counts the line bytes.
    assert_in_delta TaskLogBuffer.memory_bytes(ctx.table), real, real * 0.1
  end

  test "deletes give their line bytes back to the cap", ctx do
    start_buffer(ctx, 16 * 1024 * 1024)
    empty = TaskLogBuffer.memory_bytes(ctx.table)

    for i <- 1..100, do: TaskLogBuffer.buffer(ctx.table, "s1", "run-1", "a", distinct_line(i))
    for i <- 1..100, do: TaskLogBuffer.buffer(ctx.table, "s2", "run-1", "b", distinct_line(i))
    assert TaskLogBuffer.memory_bytes(ctx.table) > empty + 200 * @line_bytes

    TaskLogBuffer.delete_task(ctx.table, "s1", "run-1", "a")
    assert TaskLogBuffer.memory_bytes(ctx.table) < empty + 100 * @line_bytes + 50_000

    TaskLogBuffer.cleanup(ctx.table, "s2", "run-1")
    assert TaskLogBuffer.memory_bytes(ctx.table) < empty + 50_000
  end

  test "the sweep recounts the off-heap total from the rows", ctx do
    start_buffer(ctx, 16 * 1024 * 1024)
    for i <- 1..50, do: TaskLogBuffer.buffer(ctx.table, "s", "run-1", "t", distinct_line(i))
    %{off_heap: counter} = :persistent_term.get({TaskLogBuffer, ctx.table})
    :counters.put(counter, 1, 0)

    TaskLogBuffer.sweep(ctx.table, System.monotonic_time() - 1_000_000_000_000)
    assert :counters.get(counter, 1) == 50 * @line_bytes
  end

  test "a task whose lines were dropped at the cap says so at the end of its output", ctx do
    start_buffer(ctx, 64 * 1024)

    results =
      for i <- 1..100,
          do: TaskLogBuffer.buffer(ctx.table, "s", "run-1", "failing", distinct_line(i))

    dropped = Enum.count(results, &(!&1))
    assert dropped > 0

    output = TaskLogBuffer.get_output(ctx.table, "s", "run-1", "failing")
    lines = String.split(output, "\n")
    assert List.last(lines) == "[dxcore: #{dropped} log lines dropped, buffer full]"
    assert length(lines) == 100 - dropped + 1

    # The marker belongs to that run: another run of the task id has none.
    assert TaskLogBuffer.get_output(ctx.table, "s", "run-2", "failing") == ""

    TaskLogBuffer.delete_task(ctx.table, "s", "run-1", "failing")
    assert TaskLogBuffer.get_output(ctx.table, "s", "run-1", "failing") == ""
  end

  test "per-task drop markers stop at 10,000 tasks; drops past that are still counted", ctx do
    start_buffer(ctx, 1)
    for i <- 1..10_005, do: refute(TaskLogBuffer.buffer(ctx.table, "s", "run-1", "t#{i}", "x"))

    %{drops: drops, dropped: dropped} = :persistent_term.get({TaskLogBuffer, ctx.table})
    assert :ets.info(drops, :size) == 10_000
    assert :counters.get(dropped, 1) == 10_005
  end
end
