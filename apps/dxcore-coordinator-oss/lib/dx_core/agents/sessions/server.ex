defmodule DxCore.Agents.Sessions.Server do
  @moduledoc false

  use GenServer

  # ── Client API (called only by DxCore.Agents.Sessions context) ──────────

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  # ── Server callbacks ───────────────────────────────────────────────

  @impl true
  def init(_) do
    {:ok, %{sessions: %{}}}
  end

  @impl true
  def handle_call({:create_session, tenant_id}, _from, state) do
    session_id = generate_session_id()
    session = new_session(tenant_id)
    {:reply, {:ok, session_id}, %{state | sessions: Map.put(state.sessions, session_id, session)}}
  end

  @impl true
  def handle_call({:register_agent, tenant_id, session_id, agent_id}, _from, state) do
    case Map.fetch(state.sessions, session_id) do
      {:ok, %{tenant_id: ^tenant_id} = session} ->
        session = %{session | agents: MapSet.put(session.agents, agent_id)}
        {:reply, :ok, %{state | sessions: Map.put(state.sessions, session_id, session)}}

      {:ok, _session} ->
        {:reply, {:error, :unauthorized}, state}

      :error ->
        session = new_session(tenant_id, agents: [agent_id])
        state = %{state | sessions: Map.put(state.sessions, session_id, session)}
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:unregister_agent, session_id, agent_id}, _from, state) do
    sessions = state.sessions

    case Map.fetch(sessions, session_id) do
      {:ok, session} ->
        session = %{session | agents: MapSet.delete(session.agents, agent_id)}
        {:reply, :ok, %{state | sessions: Map.put(sessions, session_id, session)}}

      :error ->
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:register_run, tenant_id, session_id, run_id}, _from, state) do
    case Map.fetch(state.sessions, session_id) do
      {:ok, %{tenant_id: ^tenant_id} = session} ->
        session = %{session | run_ids: MapSet.put(session.run_ids, run_id)}
        {:reply, :ok, %{state | sessions: Map.put(state.sessions, session_id, session)}}

      {:ok, _session} ->
        {:reply, {:error, :unauthorized}, state}

      :error ->
        session = new_session(tenant_id, run_ids: [run_id])
        state = %{state | sessions: Map.put(state.sessions, session_id, session)}
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:mark_run_complete, session_id, run_id}, _from, state) do
    case Map.fetch(state.sessions, session_id) do
      {:ok, session} ->
        session = %{session | run_ids: MapSet.delete(session.run_ids, run_id)}
        remaining = MapSet.size(session.run_ids)

        {:reply, {:ok, remaining},
         %{state | sessions: Map.put(state.sessions, session_id, session)}}

      :error ->
        {:reply, {:ok, 0}, state}
    end
  end

  @impl true
  def handle_call({:finish_session, tenant_id, session_id}, _from, state) do
    case Map.fetch(state.sessions, session_id) do
      {:ok, %{tenant_id: ^tenant_id} = session} ->
        agent_ids = MapSet.to_list(session.agents)
        finished_session = %{session | status: :finished}
        sessions = Map.put(state.sessions, session_id, finished_session)

        DxCore.Agents.Web.Endpoint.broadcast!(
          "agent:#{session_id}",
          "shutdown",
          %{"reason" => "session_finished"}
        )

        {:reply, {:ok, agent_ids}, %{state | sessions: sessions}}

      {:ok, _session} ->
        {:reply, {:error, :unauthorized}, state}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:get_session, tenant_id, session_id}, _from, state) do
    case Map.fetch(state.sessions, session_id) do
      {:ok, %{tenant_id: ^tenant_id} = session} ->
        {:reply, {:ok, session}, state}

      {:ok, _session} ->
        {:reply, {:error, :unauthorized}, state}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:list_sessions, tenant_id}, _from, state) do
    tenant_sessions =
      state.sessions
      |> Enum.filter(fn {_id, session} -> session.tenant_id == tenant_id end)
      |> Map.new()

    {:reply, tenant_sessions, state}
  end

  @impl true
  def handle_call(:count_active_sessions, _from, state) do
    count = Enum.count(state.sessions, fn {_id, s} -> s.status == :active end)
    {:reply, count, state}
  end

  @impl true
  def handle_call(:list_active_session_ids, _from, state) do
    ids =
      state.sessions
      |> Enum.filter(fn {_id, s} -> s.status == :active end)
      |> Enum.map(fn {id, _s} -> id end)

    {:reply, ids, state}
  end

  @impl true
  def handle_call(:shutdown_all_sessions, _from, state) do
    {ids, sessions} =
      Enum.reduce(state.sessions, {[], state.sessions}, fn
        {id, %{status: :active} = session}, {acc_ids, acc_sessions} ->
          DxCore.Agents.Web.Endpoint.broadcast!(
            "agent:#{id}",
            "shutdown",
            %{"reason" => "coordinator_shutdown"}
          )

          {[id | acc_ids], Map.put(acc_sessions, id, %{session | status: :finished})}

        _other, acc ->
          acc
      end)

    {:reply, ids, %{state | sessions: sessions}}
  end

  defp new_session(tenant_id, opts \\ []) do
    %{
      tenant_id: tenant_id,
      run_ids: opts |> Keyword.get(:run_ids, []) |> MapSet.new(),
      agents: opts |> Keyword.get(:agents, []) |> MapSet.new(),
      status: :active
    }
  end

  defp generate_session_id do
    "ses_" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
  end
end
