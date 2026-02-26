defmodule DxCore.Agents.Web.ShutdownController do
  use DxCore.Agents.Web, :controller

  alias DxCore.Agents.Sessions

  def create(conn, _params) do
    Sessions.shutdown_all_sessions()

    # Schedule server stop after response is sent
    Task.start(fn ->
      Process.sleep(1_000)
      System.stop(0)
    end)

    json(conn, %{status: "shutting_down"})
  end
end
