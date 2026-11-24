defmodule DxCore.Agents.CLI.Test.AgentProtocol do
  @moduledoc """
  The coordinator's published agent protocol: `contract/agent-protocol.json`
  of dxcore-core, read through this package's test-only Mix path dependency
  on it (which never compiles its code), never through the coordinator's code.
  dxcore-core's own tests keep the file equal to its `TaskGraph` and
  `Scheduler`. The file reaches this package's `test` hash through its
  package.json dependency on `@repo/dxcore-core`: `test` waits for `^build`,
  and dxcore-core's `build` hashes every file of that package.
  """

  @doc "The decoded contract."
  def read do
    Mix.Project.deps_paths()
    |> Map.fetch!(:dxcore_core)
    |> Path.join("contract/agent-protocol.json")
    |> File.read!()
    |> Jason.decode!()
  end
end
