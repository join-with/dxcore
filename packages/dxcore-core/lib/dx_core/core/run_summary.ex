defmodule DxCore.Core.RunSummary do
  @moduledoc "Serializes scheduler summary maps for JSON transport over channels."

  @doc "Return an empty summary for runs with no tasks."
  def empty do
    %{
      status: :complete,
      tasks: [],
      counts: %{passed: 0, failed: 0, skipped: 0, cached: 0},
      failures: []
    }
  end

  @doc "Convert a scheduler summary (atom-keyed map) to string-keyed map for JSON."
  def serialize(summary) do
    %{
      "status" => to_string(summary.status),
      "tasks" =>
        Enum.map(summary.tasks, fn t ->
          %{
            "task_id" => t.task_id,
            "package" => t.package,
            "task" => t.task,
            "status" => to_string(t.status),
            "cached" => t.cached,
            "agent_id" => t.agent_id,
            "duration_ms" => t.duration_ms,
            "exit_code" => t.exit_code
          }
        end),
      "counts" => %{
        "passed" => summary.counts.passed,
        "failed" => summary.counts.failed,
        "skipped" => summary.counts.skipped,
        "cached" => summary.counts.cached
      },
      "failures" =>
        Enum.map(summary.failures, fn f ->
          %{
            "task_id" => f.task_id,
            "agent_id" => f.agent_id,
            "duration_ms" => f.duration_ms,
            "exit_code" => f.exit_code,
            "output" => Map.get(f, :output, "")
          }
        end)
    }
  end
end
