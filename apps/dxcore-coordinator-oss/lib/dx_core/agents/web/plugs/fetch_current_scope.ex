defmodule DxCore.Agents.Web.Plugs.FetchCurrentScope do
  @moduledoc "Extracts and verifies a Bearer token, assigning `current_scope`."

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, scope} <- DxCore.Agents.Tenants.verify_token(token) do
      assign(conn, :current_scope, scope)
    else
      _ -> conn |> send_resp(:unauthorized, "Invalid or missing token") |> halt()
    end
  end
end
