import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :dxcore_coordinator_oss, DxCore.Agents.Web.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "BCUTYN52r6HOZBWEQkM78RH6IFcsRWgA1AS0l37tc8gGzZhHbn8K94pBzeVqeeQP",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime
