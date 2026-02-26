defmodule DxCore.Core.Scheduler.NullPlugin do
  @moduledoc """
  Pass-through scheduler plugin for the OSS coordinator.

  - `select_task/3` returns the first task from the frontier list.
  - `expand_graph/2` returns the graph unchanged.
  - `on_task_complete/5` is a no-op.
  """

  @behaviour DxCore.Core.SchedulerPlugin

  @impl true
  def select_task([], _agent, _context), do: nil
  def select_task([first | _rest], _agent, _context), do: first

  @impl true
  def expand_graph(graph, _context), do: graph

  @impl true
  def on_task_complete(_task, _result, _duration_ms, _agent, _context), do: :ok
end
