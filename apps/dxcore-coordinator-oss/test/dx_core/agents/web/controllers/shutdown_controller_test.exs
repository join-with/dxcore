defmodule DxCore.Agents.Web.ShutdownControllerTest do
  use DxCore.Agents.Web.ConnCase

  alias DxCore.Agents.Sessions
  alias DxCore.Agents.Scope

  setup do
    tenant_id = "tenant-#{System.unique_integer([:positive])}"
    {:ok, token} = DxCore.Agents.Tenants.create_tenant(tenant_id, "Test Tenant")
    scope = Scope.for_tenant(tenant_id, "Test Tenant")

    %{token: token, scope: scope}
  end

  describe "create (POST /api/shutdown)" do
    test "returns 200 with shutting_down status", %{conn: conn, token: token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/shutdown")

      assert %{"status" => "shutting_down"} = json_response(conn, 200)
    end

    test "finishes all sessions and broadcasts shutdown to agents", %{
      conn: conn,
      token: token,
      scope: scope
    } do
      {:ok, session_id} = Sessions.create_session(scope)
      Sessions.register_agent(scope, session_id, "agent-1")

      # Subscribe to the agent channel topic
      DxCore.Agents.Web.Endpoint.subscribe("agent:#{session_id}")

      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> post("/api/shutdown")

      assert_receive %Phoenix.Socket.Broadcast{
        topic: "agent:" <> ^session_id,
        event: "shutdown",
        payload: %{"reason" => "coordinator_shutdown"}
      }

      # Verify session was marked as finished
      {:ok, session} = Sessions.get_session(scope, session_id)
      assert session.status == :finished
    end

    test "returns 401 without token", %{conn: conn} do
      conn = post(conn, "/api/shutdown")
      assert conn.status == 401
    end
  end
end
