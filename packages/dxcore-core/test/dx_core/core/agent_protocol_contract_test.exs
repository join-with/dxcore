defmodule DxCore.Core.AgentProtocolContractTest do
  # @repo/dxcore-contract's agent-protocol.json publishes the facts an agent
  # must meet: the task fields TaskGraph reads, how long the scheduler holds a
  # dropped agent's task, and the reasons a "shutdown" push may carry. Agents
  # (apps/dxcore-agents-cli) read that file through their own workspace
  # dependency on the contract, never this code, so these tests keep the
  # file equal to what the code does. It is read beside this package
  # (`packages/dxcore-contract`), a layout the dxcore OSS repo shares, whose
  # CI runs Mix only; package.json's devDependency reruns these tests.
  use ExUnit.Case, async: true

  alias DxCore.Core.Scheduler

  @contract_path Path.expand(
                   "../../../../dxcore-contract/agent-protocol.json",
                   __DIR__
                 )
  @task_graph_path Path.expand("../../../lib/dx_core/core/task_graph.ex", __DIR__)

  defp contract, do: @contract_path |> File.read!() |> Jason.decode!()

  test "defaultLeaseGraceMs is the scheduler's default hold on a dropped agent's task" do
    assert contract()["defaultLeaseGraceMs"] == Scheduler.default_lease_grace_ms()
  end

  test "shutdownReasons are exactly the reasons the coordinator sends" do
    assert Enum.sort(contract()["shutdownReasons"]) ==
             Enum.sort(DxCore.Core.AgentProtocol.shutdown_reasons())

    # Independent of the module: the reasons coordinators push today.
    assert Enum.sort(contract()["shutdownReasons"]) ==
             ["coordinator_shutdown", "fair_share", "no_more_work", "session_finished"]
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
    assert length(read_by_task_graph) == 10
    assert Enum.sort(contract()["taskFields"]) == Enum.sort(read_by_task_graph)
  end
end
