defmodule DxCore.Agents.Web.Router do
  use DxCore.Agents.Web, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :fetch_current_scope do
    plug DxCore.Agents.Web.Plugs.FetchCurrentScope
  end

  # Public
  scope "/api", DxCore.Agents.Web do
    pipe_through :api

    get "/health", HealthController, :index
  end

  # Authenticated
  scope "/api", DxCore.Agents.Web do
    pipe_through [:api, :fetch_current_scope]

    resources "/sessions", SessionController, only: [:create, :index, :show]
    post "/sessions/:session_id/finish", SessionController, :finish
    post "/shutdown", ShutdownController, :create
  end
end
