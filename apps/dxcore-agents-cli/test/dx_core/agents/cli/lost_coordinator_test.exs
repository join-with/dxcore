defmodule DxCore.Agents.CLI.LostCoordinatorTest do
  use ExUnit.Case, async: true

  alias DxCore.Agents.CLI.LostCoordinator

  test "the hold the agent needs covers the reconnect window, the grace, the kill wait and the report window" do
    assert LostCoordinator.lease_needed_ms() ==
             LostCoordinator.reconnect_timeout_ms() + LostCoordinator.task_grace_ms() +
               LostCoordinator.kill_after_ms() + LostCoordinator.reconnect_timeout_ms()
  end

  # The scheduler lives in another package, so the hold can't be shared code;
  # this reads its default and fails when it drops below what the agent needs.
  test "the coordinator holds a dropped agent's task at least as long as the agent may run it" do
    path =
      Path.expand(
        "../../../../../../packages/dxcore-core/lib/dx_core/core/scheduler.ex",
        __DIR__
      )

    [_, literal] = Regex.run(~r/^\s*@default_lease_grace_ms ([0-9_]+)$/m, File.read!(path))
    hold_ms = literal |> String.replace("_", "") |> String.to_integer()

    assert hold_ms >= LostCoordinator.lease_needed_ms(),
           "the scheduler holds a dropped agent's task #{hold_ms} ms, but the agent may run " <>
             "it and report it for #{LostCoordinator.lease_needed_ms()} ms"
  end
end
