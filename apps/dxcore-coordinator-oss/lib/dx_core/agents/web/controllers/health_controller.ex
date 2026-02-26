defmodule DxCore.Agents.Web.HealthController do
  use DxCore.Agents.Web, :controller

  def index(conn, _params) do
    json(conn, %{status: "ok"})
  end
end
