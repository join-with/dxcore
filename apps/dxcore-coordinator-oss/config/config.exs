# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :jw_observability,
  otp_app: :dxcore_coordinator_oss

config :dxcore_coordinator_oss,
  generators: [timestamp_type: :utc_datetime],
  scheduler_plugin: DxCore.Core.Scheduler.NullPlugin

# Configures the endpoint
config :dxcore_coordinator_oss, DxCore.Agents.Web.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: DxCore.Agents.Web.ErrorJSON],
    layout: false
  ],
  pubsub_server: DxCore.Agents.PubSub,
  live_view: [signing_salt: "L57FHb7R"]

# Configures Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.

# Prometheus metrics on a dedicated HTTP server — separate port from the main
# Phoenix endpoint, never exposed via ingress. Alloy scrapes pod-to-pod.
config :dxcore_coordinator_oss, DxCore.Agents.PromEx,
  metrics_server: [port: 4021, path: "/metrics", protocol: :http]

import_config "#{config_env()}.exs"
