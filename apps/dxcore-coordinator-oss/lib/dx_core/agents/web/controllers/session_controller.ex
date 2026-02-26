defmodule DxCore.Agents.Web.SessionController do
  use DxCore.Agents.Web, :controller

  alias DxCore.Agents.Sessions

  def create(conn, _params) do
    scope = conn.assigns.current_scope
    {:ok, session_id} = Sessions.create_session(scope)

    conn
    |> put_status(:created)
    |> json(%{session_id: session_id})
  end

  def index(conn, _params) do
    scope = conn.assigns.current_scope
    sessions = Sessions.list_sessions(scope)

    json_sessions =
      sessions
      |> Enum.map(fn {id, session} -> {id, serialize_session(session)} end)
      |> Map.new()

    json(conn, %{sessions: json_sessions})
  end

  def show(conn, %{"id" => session_id}) do
    scope = conn.assigns.current_scope

    case Sessions.get_session(scope, session_id) do
      {:ok, session} -> json(conn, %{session: serialize_session(session)})
      {:error, :not_found} -> conn |> put_status(:not_found) |> json(%{error: "not found"})
      {:error, :unauthorized} -> conn |> put_status(:forbidden) |> json(%{error: "forbidden"})
    end
  end

  def finish(conn, %{"session_id" => session_id}) do
    scope = conn.assigns.current_scope

    case Sessions.finish_session(scope, session_id) do
      {:ok, agent_ids} ->
        json(conn, %{status: "finished", agents_notified: length(agent_ids)})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "not found"})

      {:error, :unauthorized} ->
        conn |> put_status(:forbidden) |> json(%{error: "forbidden"})
    end
  end

  defp serialize_session(session) do
    session
    |> Map.update(:agents, [], &MapSet.to_list/1)
    |> Map.update(:run_ids, [], &MapSet.to_list/1)
    |> Map.update(:status, nil, &to_string/1)
  end
end
