defmodule DxCore.Core.SchedulerPlugin do
  @moduledoc """
  Behaviour for scheduler plugins that customize task selection,
  graph expansion, and task completion handling.

  The OSS coordinator uses `NullPlugin` (pass-through). The SaaS
  coordinator provides a `SmartPlugin` that uses historical data
  for smarter scheduling decisions.

  All callbacks receive a `context :: map()` parameter that carries
  tenant-scoped metadata (e.g., `tenant_id`) from the Scheduler.
  """

  alias DxCore.Core.AgentInfo
  alias DxCore.Core.Scheduler.TaskState
  alias DxCore.Core.TaskGraph

  @doc "Select a task from the frontier for the given agent. Return nil if no suitable task."
  @callback select_task(frontier :: [TaskState.t()], agent :: AgentInfo.t(), context :: map()) ::
              TaskState.t() | nil

  @doc "Expand the task graph before scheduling begins (e.g., to add shard tasks)."
  @callback expand_graph(graph :: TaskGraph.t(), context :: map()) :: TaskGraph.t()

  @doc "Called when a task completes. Used to record metrics."
  @callback on_task_complete(
              task :: TaskState.t(),
              result :: :success | :failed,
              duration_ms :: integer(),
              agent :: AgentInfo.t(),
              context :: map()
            ) :: :ok
end
