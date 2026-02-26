defmodule DxCore.Agents.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    :ets.new(:dxcore_agents_tenants, [:set, :public, :named_table, read_concurrency: true])
    DxCore.Agents.Tenants.seed_from_env()

    children = [
      DxCore.Agents.Web.Telemetry,
      {DNSCluster,
       query: Application.get_env(:dxcore_coordinator_oss, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: DxCore.Agents.PubSub},
      DxCore.Agents.Web.Presence,
      {Registry, keys: :unique, name: DxCore.Core.SchedulerRegistry},
      {DynamicSupervisor, name: DxCore.Core.SchedulerSupervisor, strategy: :one_for_one},
      DxCore.Agents.Sessions.Server,
      # Start to serve requests, typically the last entry
      DxCore.Agents.Web.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: DxCore.Agents.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    DxCore.Agents.Web.Endpoint.config_change(changed, removed)
    :ok
  end
end
