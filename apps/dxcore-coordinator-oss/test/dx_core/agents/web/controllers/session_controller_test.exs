defmodule DxCore.Agents.Web.SessionControllerTest do
  use DxCore.Agents.Web.ConnCase

  alias DxCore.Agents.Sessions
  alias DxCore.Agents.Scope

  setup do
    # Create a tenant and get its token
    tenant_id = "tenant-#{System.unique_integer([:positive])}"
    {:ok, token} = DxCore.Agents.Tenants.create_tenant(tenant_id, "Test Tenant")
    scope = Scope.for_tenant(tenant_id, "Test Tenant")

    # Create a second tenant for cross-tenant tests
    other_id = "other-#{System.unique_integer([:positive])}"
    {:ok, other_token} = DxCore.Agents.Tenants.create_tenant(other_id, "Other Tenant")
    other_scope = Scope.for_tenant(other_id, "Other Tenant")

    %{
      token: token,
      scope: scope,
      tenant_id: tenant_id,
      other_token: other_token,
      other_scope: other_scope,
      other_id: other_id
    }
  end

  describe "create" do
    test "creates a session and returns 201 with session_id", %{conn: conn, token: token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/sessions")

      assert %{"session_id" => session_id} = json_response(conn, 201)
      assert is_binary(session_id)
    end

    test "returns 401 without token", %{conn: conn} do
      conn = post(conn, "/api/sessions")
      assert conn.status == 401
    end
  end

  describe "index" do
    test "returns sessions for authenticated tenant", %{conn: conn, token: token, scope: scope} do
      {:ok, session_id} = Sessions.create_session(scope)
      Sessions.register_agent(scope, session_id, "agent-1")
      Sessions.register_agent(scope, session_id, "agent-2")

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/sessions")

      assert %{"sessions" => sessions} = json_response(conn, 200)
      assert Map.has_key?(sessions, session_id)
    end

    test "returns empty map when tenant has no sessions", %{conn: conn, token: token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/sessions")

      assert %{"sessions" => sessions} = json_response(conn, 200)
      assert sessions == %{}
    end

    test "returns 401 without token", %{conn: conn} do
      conn = get(conn, "/api/sessions")
      assert conn.status == 401
    end
  end

  describe "show" do
    test "returns session detail for own session", %{conn: conn, token: token, scope: scope} do
      {:ok, session_id} = Sessions.create_session(scope)
      Sessions.register_agent(scope, session_id, "agent-1")

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/sessions/#{session_id}")

      assert %{"session" => session} = json_response(conn, 200)
      assert session["tenant_id"] == scope.tenant_id
    end

    test "returns 404 for non-existent session", %{conn: conn, token: token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/sessions/nonexistent-session")

      assert %{"error" => "not found"} = json_response(conn, 404)
    end

    test "returns 403 for another tenant's session", %{
      conn: conn,
      other_token: other_token,
      scope: scope
    } do
      {:ok, session_id} = Sessions.create_session(scope)
      Sessions.register_agent(scope, session_id, "agent-1")

      # Try to access with other tenant's token
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{other_token}")
        |> get("/api/sessions/#{session_id}")

      assert %{"error" => "forbidden"} = json_response(conn, 403)
    end

    test "returns 401 without token", %{conn: conn} do
      conn = get(conn, "/api/sessions/some-session")
      assert conn.status == 401
    end
  end

  describe "finish" do
    test "finishes session, broadcasts shutdown, returns agent count", %{
      conn: conn,
      token: token,
      scope: scope
    } do
      {:ok, session_id} = Sessions.create_session(scope)
      Sessions.register_agent(scope, session_id, "agent-1")
      Sessions.register_agent(scope, session_id, "agent-2")

      # Subscribe to the agent channel topic to verify broadcast
      DxCore.Agents.Web.Endpoint.subscribe("agent:#{session_id}")

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/sessions/#{session_id}/finish")

      assert %{"status" => "finished", "agents_notified" => 2} = json_response(conn, 200)

      # Verify the shutdown broadcast was sent
      assert_receive %Phoenix.Socket.Broadcast{
        topic: "agent:" <> ^session_id,
        event: "shutdown",
        payload: %{"reason" => "session_finished"}
      }
    end

    test "returns 404 for non-existent session", %{conn: conn, token: token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/sessions/nonexistent-session/finish")

      assert %{"error" => "not found"} = json_response(conn, 404)
    end

    test "returns 403 for another tenant's session", %{
      conn: conn,
      other_token: other_token,
      scope: scope
    } do
      {:ok, session_id} = Sessions.create_session(scope)
      Sessions.register_agent(scope, session_id, "agent-1")

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{other_token}")
        |> post("/api/sessions/#{session_id}/finish")

      assert %{"error" => "forbidden"} = json_response(conn, 403)
    end

    test "returns 401 without token", %{conn: conn} do
      conn = post(conn, "/api/sessions/some-session/finish")
      assert conn.status == 401
    end
  end
end
