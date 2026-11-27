defmodule DxCore.Agents.CLI.Test.AgentProtocol do
  @moduledoc """
  The coordinator's published agent protocol: `agent-protocol.json` of
  `@repo/dxcore-contract`, read through `DxCore.Agents.CLI.Contract`, never
  through the coordinator's code.
  dxcore-core's own tests keep the file equal to its `TaskGraph` and
  `Scheduler`. The file reaches this package's `test` hash through its
  package.json dependency on the contract: `test` waits for `^compile-js`,
  the contract's one task, which hashes its JSON.
  """

  alias DxCore.Agents.CLI.Contract

  @doc "The decoded contract."
  def read, do: Contract.read!("agent-protocol.json")
end
