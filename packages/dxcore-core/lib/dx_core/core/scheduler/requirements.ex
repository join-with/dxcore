defmodule DxCore.Core.Scheduler.Requirements do
  @moduledoc """
  Whether an agent fits a task: every requirement key of the task equals the
  agent's tag of that key. A task with no requirements fits every agent; an
  agent with no tags fits only those.

  The one definition both the scheduler plugin's choice of task and
  `DxCore.Core.Scheduler.LeaveRule` use, so the two can never disagree about
  which agent can run what.
  """

  @spec fits?(requirements :: map() | nil, tags :: map() | nil) :: boolean()
  def fits?(requirements, _tags) when requirements in [nil, %{}], do: true
  def fits?(_requirements, nil), do: false

  def fits?(requirements, tags) when is_map(requirements) and is_map(tags) do
    Enum.all?(requirements, fn {key, val} -> Map.get(tags, key) == val end)
  end
end
