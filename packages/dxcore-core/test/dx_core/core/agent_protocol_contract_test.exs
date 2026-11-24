defmodule DxCore.Core.AgentProtocolContractTest do
  # contract/agent-protocol.json publishes the facts an agent must meet:
  # the task fields TaskGraph reads and how long the scheduler holds a
  # dropped agent's task. Agents (apps/dxcore-agents-cli) read that file
  # through their workspace dependency on this package, never this code, so
  # these tests keep the file equal to what the code does.
  use ExUnit.Case, async: true

  alias DxCore.Core.Scheduler

  @contract_path Path.expand("../../../contract/agent-protocol.json", __DIR__)
  @task_graph_path Path.expand("../../../lib/dx_core/core/task_graph.ex", __DIR__)

  defp contract, do: @contract_path |> File.read!() |> Jason.decode!()

  test "defaultLeaseGraceMs is the scheduler's default hold on a dropped agent's task" do
    assert contract()["defaultLeaseGraceMs"] == Scheduler.default_lease_grace_ms()
  end

  test "taskFields are exactly the task fields TaskGraph reads" do
    read_by_task_graph =
      Regex.scan(
        ~r/raw\["([A-Za-z]+)"\]|defp parse_[a-z_]+\(%\{"([A-Za-z]+)"/,
        File.read!(@task_graph_path)
      )
      |> Enum.map(fn [_ | groups] -> Enum.find(groups, &(&1 != "")) end)
      |> Enum.uniq()

    # Guards the scan itself: a rewrite of parse_task/1 that the pattern no
    # longer matches would otherwise compare two short lists.
    assert length(read_by_task_graph) == 11
    assert Enum.sort(contract()["taskFields"]) == Enum.sort(read_by_task_graph)
  end
end
