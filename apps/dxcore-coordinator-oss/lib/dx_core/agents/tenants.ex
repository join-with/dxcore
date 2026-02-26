defmodule DxCore.Agents.Tenants do
  @moduledoc "Phoenix Context for tenant management. ETS-backed (no DB for POC)."

  alias DxCore.Agents.Scope
  alias DxCore.Agents.Tenants.Tenant

  @table :dxcore_agents_tenants

  @doc """
  Verifies a raw API token by hashing it and looking up the tenant in ETS.
  Returns `{:ok, %Scope{}}` on success, `:error` on failure.
  """
  @spec verify_token(binary()) :: {:ok, Scope.t()} | :error
  def verify_token(raw_token) do
    hash = :crypto.hash(:sha256, raw_token)

    case :ets.lookup(@table, hash) do
      [{^hash, %Tenant{id: id, name: name}}] ->
        {:ok, Scope.for_tenant(id, name)}

      [] ->
        :error
    end
  end

  @doc """
  Creates a new tenant with a `tdx_`-prefixed API token.
  Returns `{:ok, raw_token}` where `raw_token` is the plain-text token
  that must be stored securely by the caller (it is never persisted).
  """
  @spec create_tenant(binary(), binary()) :: {:ok, binary()}
  def create_tenant(id, name) do
    raw_token = "tdx_" <> (:crypto.strong_rand_bytes(32) |> Base.url_encode64())
    hash = :crypto.hash(:sha256, raw_token)
    tenant = %Tenant{id: id, name: name, token_hash: hash}
    :ets.insert(@table, {hash, tenant})
    {:ok, raw_token}
  end

  @doc """
  Lists all tenants without exposing token hashes.
  """
  @spec list_tenants() :: [Tenant.t()]
  def list_tenants do
    @table
    |> :ets.tab2list()
    |> Enum.map(fn {_hash, %Tenant{} = tenant} -> %Tenant{tenant | token_hash: nil} end)
  end

  @doc """
  Seeds tenants from the `DXCORE_AGENTS_TOKENS` environment variable.
  Format: `id:token,id:token`. Name defaults to id.
  """
  @spec seed_from_env() :: :ok
  def seed_from_env do
    case System.get_env("DXCORE_AGENTS_TOKENS") do
      nil ->
        :ok

      "" ->
        :ok

      tokens_str ->
        tokens_str
        |> String.split(",", trim: true)
        |> Enum.each(fn pair ->
          [id, token] = String.split(pair, ":", parts: 2)
          hash = :crypto.hash(:sha256, token)
          tenant = %Tenant{id: id, name: id, token_hash: hash}
          :ets.insert(@table, {hash, tenant})
        end)
    end
  end
end
