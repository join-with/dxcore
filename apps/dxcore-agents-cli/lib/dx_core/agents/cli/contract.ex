defmodule DxCore.Agents.CLI.Contract do
  @moduledoc """
  dxcore's wire facts, written once as data in `@repo/dxcore-contract`
  (packages/dxcore-contract, #18951), read at compile time. A module that
  embeds a value names the file in its own `@external_resource`, so a changed
  value recompiles it; package.json lists the contract, so turbo reruns this
  app's tasks through `^compile-js`.

  The file is read at `packages/dxcore-contract` beside this app's
  `apps/dxcore-agents-cli`, not through the pnpm link: the dxcore OSS repo
  (`.github/workflows/sync-dxcore-oss.yml`) has the same layout but its CI
  runs Mix only, with no `node_modules`.
  """

  @dir Path.expand("../../../../../../packages/dxcore-contract", __DIR__)

  @doc "The absolute path of a contract file, for `@external_resource`."
  @spec path(String.t()) :: String.t()
  def path(file), do: Path.join(@dir, file)

  @doc "A contract file, decoded. For module bodies, at compile time, and tests."
  @spec read!(String.t()) :: map()
  def read!(file), do: file |> path() |> File.read!() |> Jason.decode!()
end
