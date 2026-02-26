defmodule DxCore.Agents.Tenants.Tenant do
  @moduledoc "Represents a tenant with a hashed API token."
  defstruct [:id, :name, :token_hash]
end
