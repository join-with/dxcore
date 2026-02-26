defmodule DxCore.Agents.Web.Plugs.FetchCurrentScopeTest do
  use DxCore.Agents.Web.ConnCase

  alias DxCore.Agents.Web.Plugs.FetchCurrentScope

  setup do
    {:ok, token} = DxCore.Agents.Tenants.create_tenant("test-tenant", "Test Tenant")
    %{token: token}
  end

  test "assigns current_scope with valid Bearer token", %{conn: conn, token: token} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> FetchCurrentScope.call([])

    refute conn.halted

    assert %DxCore.Agents.Scope{tenant_id: "test-tenant", tenant_name: "Test Tenant"} =
             conn.assigns.current_scope
  end

  test "returns 401 with invalid token", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer invalid-token")
      |> FetchCurrentScope.call([])

    assert conn.halted
    assert conn.status == 401
  end

  test "returns 401 with missing Authorization header", %{conn: conn} do
    conn = FetchCurrentScope.call(conn, [])

    assert conn.halted
    assert conn.status == 401
  end

  test "returns 401 with malformed Authorization header", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Token some-token")
      |> FetchCurrentScope.call([])

    assert conn.halted
    assert conn.status == 401
  end
end
