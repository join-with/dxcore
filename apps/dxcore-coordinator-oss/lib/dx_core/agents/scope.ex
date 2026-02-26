defmodule DxCore.Agents.Scope do
  @moduledoc "Carries tenant identity through all layers."
  defstruct [:tenant_id, :tenant_name]

  def for_tenant(tenant_id, tenant_name) do
    %__MODULE__{tenant_id: tenant_id, tenant_name: tenant_name}
  end
end
