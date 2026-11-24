defmodule DxCore.Agents.CLI.LostCoordinatorTest do
  use ExUnit.Case, async: true

  alias DxCore.Agents.CLI.LostCoordinator
  alias DxCore.Agents.CLI.Test.AgentProtocol

  test "the hold the agent needs covers the reconnect window, the grace, the kill wait and the report window" do
    assert LostCoordinator.lease_needed_ms() ==
             LostCoordinator.reconnect_timeout_ms() + LostCoordinator.task_grace_ms() +
               LostCoordinator.kill_after_ms() + LostCoordinator.reconnect_timeout_ms()
  end

  # The scheduler lives in another package, so the hold can't be shared code;
  # dxcore-core publishes its default in its agent protocol contract, and this
  # fails when it drops below what the agent needs.
  test "the coordinator holds a dropped agent's task at least as long as the agent may run it" do
    hold_ms = AgentProtocol.read()["defaultLeaseGraceMs"]

    # A missing or non-integer value would compare above any number in term
    # order and pass the check below without testing anything.
    assert is_integer(hold_ms), "defaultLeaseGraceMs is #{inspect(hold_ms)}, not an integer"

    assert hold_ms >= LostCoordinator.lease_needed_ms(),
           "the scheduler holds a dropped agent's task #{hold_ms} ms, but the agent may run " <>
             "it and report it for #{LostCoordinator.lease_needed_ms()} ms"
  end
end
