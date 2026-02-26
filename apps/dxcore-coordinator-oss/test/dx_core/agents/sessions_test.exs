defmodule DxCore.Agents.SessionsTest do
  use ExUnit.Case, async: false

  alias DxCore.Agents.Sessions
  alias DxCore.Agents.Scope

  defp unique_id(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"

  defp scope(tenant_id \\ nil) do
    tid = tenant_id || unique_id("tenant")
    Scope.for_tenant(tid, "#{tid} Corp")
  end

  describe "create_session/1" do
    test "creates a new session and returns server-generated id" do
      s = scope()
      assert {:ok, session_id} = Sessions.create_session(s)
      assert is_binary(session_id)

      assert {:ok, session} = Sessions.get_session(s, session_id)
      assert session.tenant_id == s.tenant_id
      assert session.status == :active
    end

    test "each call returns a unique session id" do
      s = scope()
      {:ok, id1} = Sessions.create_session(s)
      {:ok, id2} = Sessions.create_session(s)
      assert id1 != id2
    end
  end

  describe "register_agent/3" do
    test "auto-creates session when registering agent to non-existent session" do
      s = scope()
      session_id = unique_id("session")
      assert :ok = Sessions.register_agent(s, session_id, "agent-1")

      {:ok, session} = Sessions.get_session(s, session_id)
      assert MapSet.member?(session.agents, "agent-1")
      assert session.status == :active
    end

    test "adds agent to existing session" do
      s = scope()
      {:ok, session_id} = Sessions.create_session(s)
      agent_id = unique_id("agent")

      assert :ok = Sessions.register_agent(s, session_id, agent_id)
      {:ok, session} = Sessions.get_session(s, session_id)
      assert MapSet.member?(session.agents, agent_id)
    end

    test "adds multiple agents to existing session" do
      s = scope()
      {:ok, session_id} = Sessions.create_session(s)
      agent1 = unique_id("agent")
      agent2 = unique_id("agent")

      :ok = Sessions.register_agent(s, session_id, agent1)
      :ok = Sessions.register_agent(s, session_id, agent2)

      {:ok, session} = Sessions.get_session(s, session_id)
      assert MapSet.member?(session.agents, agent1)
      assert MapSet.member?(session.agents, agent2)
      assert MapSet.size(session.agents) == 2
    end

    test "returns error for wrong tenant on existing session" do
      owner = scope("owner")
      other = scope("intruder")
      {:ok, session_id} = Sessions.create_session(owner)

      assert {:error, :unauthorized} =
               Sessions.register_agent(other, session_id, unique_id("agent"))
    end
  end

  describe "unregister_agent/2" do
    test "removes agent from session" do
      s = scope()
      {:ok, session_id} = Sessions.create_session(s)
      agent_id = unique_id("agent")

      :ok = Sessions.register_agent(s, session_id, agent_id)
      assert :ok = Sessions.unregister_agent(session_id, agent_id)

      {:ok, session} = Sessions.get_session(s, session_id)
      refute MapSet.member?(session.agents, agent_id)
    end
  end

  describe "register_run/3" do
    test "auto-creates session when registering run to non-existent session" do
      s = scope()
      session_id = unique_id("session")
      run_id = unique_id("run")

      assert :ok = Sessions.register_run(s, session_id, run_id)

      {:ok, session} = Sessions.get_session(s, session_id)
      assert MapSet.member?(session.run_ids, run_id)
      assert session.status == :active
    end

    test "validates tenant ownership and adds run" do
      s = scope()
      {:ok, session_id} = Sessions.create_session(s)
      run_id = unique_id("run")

      assert :ok = Sessions.register_run(s, session_id, run_id)

      {:ok, session} = Sessions.get_session(s, session_id)
      assert MapSet.member?(session.run_ids, run_id)
    end

    test "returns error for wrong tenant" do
      owner = scope("owner")
      other = scope("intruder")
      {:ok, session_id} = Sessions.create_session(owner)

      :ok = Sessions.register_agent(owner, session_id, unique_id("agent"))
      assert {:error, :unauthorized} = Sessions.register_run(other, session_id, unique_id("run"))
    end
  end

  describe "mark_run_complete/2" do
    test "marks run as complete by removing it from run_ids" do
      s = scope()
      {:ok, session_id} = Sessions.create_session(s)
      run_id = unique_id("run")

      :ok = Sessions.register_agent(s, session_id, unique_id("agent"))
      :ok = Sessions.register_run(s, session_id, run_id)
      assert {:ok, 0} = Sessions.mark_run_complete(session_id, run_id)

      {:ok, session} = Sessions.get_session(s, session_id)
      refute MapSet.member?(session.run_ids, run_id)
    end
  end

  describe "finish_session/2" do
    test "returns agent_ids and marks session finished" do
      s = scope()
      {:ok, session_id} = Sessions.create_session(s)
      agent1 = unique_id("agent")
      agent2 = unique_id("agent")

      :ok = Sessions.register_agent(s, session_id, agent1)
      :ok = Sessions.register_agent(s, session_id, agent2)

      assert {:ok, agent_ids} = Sessions.finish_session(s, session_id)
      assert Enum.sort(agent_ids) == Enum.sort([agent1, agent2])

      {:ok, session} = Sessions.get_session(s, session_id)
      assert session.status == :finished
    end

    test "returns error for wrong tenant" do
      owner = scope("owner")
      other = scope("intruder")
      {:ok, session_id} = Sessions.create_session(owner)

      :ok = Sessions.register_agent(owner, session_id, unique_id("agent"))
      assert {:error, :unauthorized} = Sessions.finish_session(other, session_id)
    end

    test "returns error for non-existent session" do
      s = scope()
      assert {:error, :not_found} = Sessions.finish_session(s, unique_id("session"))
    end
  end

  describe "get_session/2" do
    test "returns session data for correct tenant" do
      s = scope()
      {:ok, session_id} = Sessions.create_session(s)

      :ok = Sessions.register_agent(s, session_id, unique_id("agent"))
      assert {:ok, session} = Sessions.get_session(s, session_id)
      assert session.tenant_id == s.tenant_id
      assert session.status == :active
    end

    test "returns error for wrong tenant" do
      owner = scope("owner")
      other = scope("intruder")
      {:ok, session_id} = Sessions.create_session(owner)

      :ok = Sessions.register_agent(owner, session_id, unique_id("agent"))
      assert {:error, :unauthorized} = Sessions.get_session(other, session_id)
    end

    test "returns error for non-existent session" do
      s = scope()
      assert {:error, :not_found} = Sessions.get_session(s, unique_id("session"))
    end
  end

  describe "list_active_session_ids/0" do
    test "returns IDs of active sessions" do
      scope = Scope.for_tenant("t1", "Tenant 1")
      {:ok, s1} = Sessions.create_session(scope)
      {:ok, s2} = Sessions.create_session(scope)
      {:ok, _s3} = Sessions.create_session(scope)

      # Finish s2 so it's not active
      Sessions.finish_session(scope, s2)

      ids = Sessions.list_active_session_ids()
      assert s1 in ids
      refute s2 in ids
      assert length(ids) >= 2
    end
  end

  describe "shutdown_all_sessions/0" do
    test "marks all active sessions as finished and returns their IDs" do
      s = scope()
      {:ok, s1} = Sessions.create_session(s)
      {:ok, s2} = Sessions.create_session(s)
      {:ok, s3} = Sessions.create_session(s)

      # Finish s2 so it's already inactive
      Sessions.finish_session(s, s2)

      ids = Sessions.shutdown_all_sessions()
      assert s1 in ids
      refute s2 in ids
      assert s3 in ids

      # Verify all are now finished
      {:ok, session1} = Sessions.get_session(s, s1)
      {:ok, session3} = Sessions.get_session(s, s3)
      assert session1.status == :finished
      assert session3.status == :finished
    end

    test "returns empty list when called again (all already finished)" do
      # First call shuts down any active sessions from other tests
      Sessions.shutdown_all_sessions()
      # Second call should return empty
      assert [] = Sessions.shutdown_all_sessions()
    end
  end

  describe "list_sessions/1" do
    test "filters by tenant" do
      tenant_a = scope("tenant_a")
      tenant_b = scope("tenant_b")
      {:ok, session_a} = Sessions.create_session(tenant_a)
      {:ok, session_b} = Sessions.create_session(tenant_b)

      :ok = Sessions.register_agent(tenant_a, session_a, unique_id("agent"))
      :ok = Sessions.register_agent(tenant_b, session_b, unique_id("agent"))

      a_sessions = Sessions.list_sessions(tenant_a)
      assert Map.has_key?(a_sessions, session_a)
      refute Map.has_key?(a_sessions, session_b)

      b_sessions = Sessions.list_sessions(tenant_b)
      assert Map.has_key?(b_sessions, session_b)
      refute Map.has_key?(b_sessions, session_a)
    end
  end

  describe "auto-create session" do
    test "concurrent auto-creates don't fail" do
      s = scope()
      session_id = unique_id("auto_session")

      tasks =
        for i <- 1..5 do
          Task.async(fn ->
            Sessions.register_agent(s, session_id, "agent-#{i}")
          end)
        end

      results = Task.await_many(tasks)
      assert Enum.all?(results, &(&1 == :ok))

      {:ok, session} = Sessions.get_session(s, session_id)
      assert MapSet.size(session.agents) == 5
    end
  end
end
