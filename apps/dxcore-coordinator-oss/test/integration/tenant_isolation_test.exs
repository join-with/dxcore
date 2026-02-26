defmodule DxCore.Agents.Integration.TenantIsolationTest do
  @moduledoc """
  Integration test that verifies cross-tenant isolation:

  1. Tenant B cannot see Tenant A's sessions via the REST API.
  2. Tenant B cannot finish Tenant A's sessions via the REST API.
  3. Sessions context rejects register_run for wrong tenant.
  4. Each tenant gets separate scheduler processes.
  """

  use DxCore.Agents.Web.ConnCase

  # ConnCase imports Plug.Conn (which has push/3). To avoid clashing with
  # Phoenix.ChannelTest.push/3, we import channel helpers except push and
  # call Phoenix.ChannelTest.push/3 explicitly.
  import Phoenix.ChannelTest, except: [push: 3]

  alias DxCore.Agents.{Scope, Sessions}

  @endpoint DxCore.Agents.Web.Endpoint
  @fixtures_dir Path.join([__DIR__, "..", "fixtures"])

  setup do
    {:ok, token_a} = DxCore.Agents.Tenants.create_tenant("tenant-a", "Tenant A")
    {:ok, token_b} = DxCore.Agents.Tenants.create_tenant("tenant-b", "Tenant B")

    scope_a = Scope.for_tenant("tenant-a", "Tenant A")
    scope_b = Scope.for_tenant("tenant-b", "Tenant B")

    %{
      token_a: token_a,
      token_b: token_b,
      scope_a: scope_a,
      scope_b: scope_b
    }
  end

  describe "API isolation" do
    test "tenant B cannot see tenant A's sessions via GET /api/sessions/:id", ctx do
      # Tenant A creates a session explicitly
      {:ok, session_id} = Sessions.create_session(ctx.scope_a)

      # Tenant A creates a session via channel
      {:ok, _, disp} =
        DxCore.Agents.Web.DispatcherSocket
        |> socket("user", %{current_scope: ctx.scope_a})
        |> subscribe_and_join(DxCore.Agents.Web.DispatcherChannel, "dispatcher:#{session_id}")

      json = File.read!(Path.join(@fixtures_dir, "dry_run_simple.json"))
      {:ok, parsed} = Jason.decode(json)

      ref =
        Phoenix.ChannelTest.push(disp, "submit_graph", %{
          "run_id" => "run-1",
          "tasks" => parsed["tasks"]
        })

      assert_reply ref, :ok, _

      # Tenant B tries to view session -- should get 403
      conn_b =
        build_conn()
        |> put_req_header("authorization", "Bearer #{ctx.token_b}")
        |> get("/api/sessions/#{session_id}")

      assert %{"error" => "forbidden"} = json_response(conn_b, 403)

      # Tenant A can view it -- should get 200
      conn_a =
        build_conn()
        |> put_req_header("authorization", "Bearer #{ctx.token_a}")
        |> get("/api/sessions/#{session_id}")

      assert %{"session" => session} = json_response(conn_a, 200)
      assert session["tenant_id"] == "tenant-a"

      leave(disp)
    end

    test "tenant B cannot list tenant A's sessions via GET /api/sessions", ctx do
      # Tenant A creates a session explicitly
      {:ok, session_id} = Sessions.create_session(ctx.scope_a)
      Sessions.register_agent(ctx.scope_a, session_id, "agent-1")

      # Tenant B lists sessions -- should not see tenant A's session
      conn_b =
        build_conn()
        |> put_req_header("authorization", "Bearer #{ctx.token_b}")
        |> get("/api/sessions")

      assert %{"sessions" => sessions} = json_response(conn_b, 200)
      refute Map.has_key?(sessions, session_id)

      # Tenant A lists sessions -- should see their session
      conn_a =
        build_conn()
        |> put_req_header("authorization", "Bearer #{ctx.token_a}")
        |> get("/api/sessions")

      assert %{"sessions" => sessions_a} = json_response(conn_a, 200)
      assert Map.has_key?(sessions_a, session_id)
    end

    test "tenant B cannot finish tenant A's session", ctx do
      # Tenant A creates a session explicitly
      {:ok, session_id} = Sessions.create_session(ctx.scope_a)
      Sessions.register_agent(ctx.scope_a, session_id, "agent-1")

      # Tenant B tries to finish -- should get 403
      conn_b =
        build_conn()
        |> put_req_header("authorization", "Bearer #{ctx.token_b}")
        |> post("/api/sessions/#{session_id}/finish")

      assert %{"error" => "forbidden"} = json_response(conn_b, 403)

      # Tenant A can finish -- should get 200
      conn_a =
        build_conn()
        |> put_req_header("authorization", "Bearer #{ctx.token_a}")
        |> post("/api/sessions/#{session_id}/finish")

      assert %{"status" => "finished"} = json_response(conn_a, 200)
    end
  end

  describe "Sessions context isolation" do
    test "register_agent returns :error for wrong tenant on existing session", ctx do
      # Tenant A creates session explicitly
      {:ok, session_id} = Sessions.create_session(ctx.scope_a)
      assert :ok = Sessions.register_agent(ctx.scope_a, session_id, "agent-1")

      # Tenant B cannot register an agent on tenant A's session
      assert {:error, :unauthorized} =
               Sessions.register_agent(ctx.scope_b, session_id, "agent-bad")
    end

    test "register_run returns :error for wrong tenant", ctx do
      # Tenant A creates session explicitly
      {:ok, session_id} = Sessions.create_session(ctx.scope_a)
      Sessions.register_agent(ctx.scope_a, session_id, "agent-1")

      # Tenant A can register a run
      assert :ok = Sessions.register_run(ctx.scope_a, session_id, "run-ok")

      # Tenant B cannot register a run on tenant A's session
      assert {:error, :unauthorized} =
               Sessions.register_run(ctx.scope_b, session_id, "run-bad")
    end

    test "get_session returns :error for wrong tenant", ctx do
      {:ok, session_id} = Sessions.create_session(ctx.scope_a)
      Sessions.register_agent(ctx.scope_a, session_id, "agent-1")

      assert {:ok, _session} = Sessions.get_session(ctx.scope_a, session_id)
      assert {:error, :unauthorized} = Sessions.get_session(ctx.scope_b, session_id)
    end

    test "finish_session returns :error for wrong tenant", ctx do
      {:ok, session_id} = Sessions.create_session(ctx.scope_a)
      Sessions.register_agent(ctx.scope_a, session_id, "agent-1")

      assert {:error, :unauthorized} = Sessions.finish_session(ctx.scope_b, session_id)
      assert {:ok, _agents} = Sessions.finish_session(ctx.scope_a, session_id)
    end
  end

  describe "scheduler isolation across tenants" do
    test "each tenant gets separate scheduler processes", ctx do
      {:ok, session_a} = Sessions.create_session(ctx.scope_a)
      {:ok, session_b} = Sessions.create_session(ctx.scope_b)

      json = File.read!(Path.join(@fixtures_dir, "dry_run_simple.json"))
      {:ok, parsed} = Jason.decode(json)

      # Tenant A submits a graph
      {:ok, _, disp_a} =
        DxCore.Agents.Web.DispatcherSocket
        |> socket("user_a", %{current_scope: ctx.scope_a})
        |> subscribe_and_join(DxCore.Agents.Web.DispatcherChannel, "dispatcher:#{session_a}")

      ref_a =
        Phoenix.ChannelTest.push(disp_a, "submit_graph", %{
          "run_id" => "run-a",
          "tasks" => parsed["tasks"]
        })

      assert_reply ref_a, :ok, %{"total_tasks" => 4}

      # Tenant B submits a graph
      {:ok, _, disp_b} =
        DxCore.Agents.Web.DispatcherSocket
        |> socket("user_b", %{current_scope: ctx.scope_b})
        |> subscribe_and_join(DxCore.Agents.Web.DispatcherChannel, "dispatcher:#{session_b}")

      ref_b =
        Phoenix.ChannelTest.push(disp_b, "submit_graph", %{
          "run_id" => "run-b",
          "tasks" => parsed["tasks"]
        })

      assert_reply ref_b, :ok, %{"total_tasks" => 4}

      # Verify separate scheduler PIDs
      [{pid_a, "run-a"}] = Sessions.get_scheduler_pids(session_a)
      [{pid_b, "run-b"}] = Sessions.get_scheduler_pids(session_b)
      assert pid_a != pid_b

      # Verify tenant A scheduler doesn't know about tenant B's run
      status_a = DxCore.Agents.Scheduler.status(pid_a)
      assert status_a.run_id == "run-a"

      status_b = DxCore.Agents.Scheduler.status(pid_b)
      assert status_b.run_id == "run-b"

      leave(disp_a)
      leave(disp_b)
    end
  end
end
