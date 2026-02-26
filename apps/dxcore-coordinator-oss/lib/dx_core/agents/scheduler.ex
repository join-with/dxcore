defmodule DxCore.Agents.Scheduler do
  @moduledoc "Thin delegate to DxCore.Core.Scheduler."

  defdelegate start_link(opts), to: DxCore.Core.Scheduler
  defdelegate whereis(session_id, run_id), to: DxCore.Core.Scheduler
  defdelegate request_task(pid, agent_id), to: DxCore.Core.Scheduler
  defdelegate request_task(pid, agent_id, agent_info), to: DxCore.Core.Scheduler
  defdelegate report_result(pid, task_id, result), to: DxCore.Core.Scheduler
  defdelegate reassign_task(pid, agent_id), to: DxCore.Core.Scheduler
  defdelegate status(pid), to: DxCore.Core.Scheduler
end
