defmodule DxCore.Agents.Sessions do
  @moduledoc "Phoenix Context wrapping session lifecycle."

  alias DxCore.Agents.Scope
  alias DxCore.Agents.Sessions.Server

  @doc """
  Create a new session owned by the scope's tenant.
  Returns a server-generated session ID.
  """
  @spec create_session(Scope.t()) :: {:ok, binary()}
  def create_session(%Scope{tenant_id: tenant_id}) do
    GenServer.call(Server, {:create_session, tenant_id})
  end

  @doc """
  Add an agent to a session. Auto-creates the session if it doesn't exist.
  """
  @spec register_agent(Scope.t(), binary(), binary()) ::
          :ok | {:error, :unauthorized}
  def register_agent(%Scope{tenant_id: tenant_id}, session_id, agent_id) do
    GenServer.call(Server, {:register_agent, tenant_id, session_id, agent_id})
  end

  @doc """
  Remove an agent from a session. Internal use, no scope needed.
  """
  @spec unregister_agent(binary(), binary()) :: :ok
  def unregister_agent(session_id, agent_id) do
    GenServer.call(Server, {:unregister_agent, session_id, agent_id})
  end

  @doc """
  Add a run to a session. Auto-creates the session if it doesn't exist.
  """
  @spec register_run(Scope.t(), binary(), binary()) ::
          :ok | {:error, :unauthorized}
  def register_run(%Scope{tenant_id: tenant_id}, session_id, run_id) do
    GenServer.call(Server, {:register_run, tenant_id, session_id, run_id})
  end

  @doc """
  Mark a run as complete/terminal, removing it from the session's active runs.
  Returns `{:ok, remaining_runs}` with the count of still-active runs.
  """
  @spec mark_run_complete(binary(), binary()) :: {:ok, non_neg_integer()}
  def mark_run_complete(session_id, run_id) do
    GenServer.call(Server, {:mark_run_complete, session_id, run_id})
  end

  @doc """
  Mark a session as finished and broadcast shutdown to its agents.
  Returns the list of agent IDs in the session.
  """
  @spec finish_session(Scope.t(), binary()) ::
          {:ok, [binary()]} | {:error, :unauthorized} | {:error, :not_found}
  def finish_session(%Scope{tenant_id: tenant_id}, session_id) do
    GenServer.call(Server, {:finish_session, tenant_id, session_id})
  end

  @doc """
  Return `[{pid, run_id}]` for all schedulers registered under `session_id`.
  """
  @spec get_scheduler_pids(binary()) :: [{pid(), binary()}]
  def get_scheduler_pids(session_id) do
    DxCore.Core.Scheduler.list_for_session(session_id)
  end

  @doc """
  Get session data. Validates tenant ownership.
  """
  @spec get_session(Scope.t(), binary()) ::
          {:ok, map()} | {:error, :unauthorized} | {:error, :not_found}
  def get_session(%Scope{tenant_id: tenant_id}, session_id) do
    GenServer.call(Server, {:get_session, tenant_id, session_id})
  end

  @doc """
  List all sessions belonging to the scope's tenant.
  """
  @spec list_sessions(Scope.t()) :: map()
  def list_sessions(%Scope{tenant_id: tenant_id}) do
    GenServer.call(Server, {:list_sessions, tenant_id})
  end

  @doc """
  Return count of sessions with status :active (across all tenants).
  """
  @spec list_active_sessions() :: non_neg_integer()
  def list_active_sessions do
    GenServer.call(Server, :count_active_sessions)
  end

  @doc "Return list of session IDs with status :active (across all tenants)."
  @spec list_active_session_ids() :: [binary()]
  def list_active_session_ids do
    GenServer.call(Server, :list_active_session_ids)
  end

  @doc "Mark all active sessions as finished, broadcasting shutdown to each session's agents. Returns list of session IDs that were shut down."
  @spec shutdown_all_sessions() :: [binary()]
  def shutdown_all_sessions do
    GenServer.call(Server, :shutdown_all_sessions)
  end
end
