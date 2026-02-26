defmodule DxCore.Agents.Web.AgentSocketTest do
  use DxCore.Agents.Web.ChannelCase

  setup do
    {:ok, token} = DxCore.Agents.Tenants.create_tenant("test-tenant", "Test Tenant")
    %{token: token}
  end

  test "connect with valid token assigns current_scope", %{token: token} do
    assert {:ok, socket} = connect(DxCore.Agents.Web.AgentSocket, %{"token" => token})
    assert %DxCore.Agents.Scope{tenant_id: "test-tenant"} = socket.assigns.current_scope
  end

  test "connect without token returns error" do
    assert :error = connect(DxCore.Agents.Web.AgentSocket, %{})
  end

  test "connect with invalid token returns error" do
    assert :error = connect(DxCore.Agents.Web.AgentSocket, %{"token" => "bad-token"})
  end
end
