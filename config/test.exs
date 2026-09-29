import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :eth, Eth.Repo,
  username: "postgres",
  password: "postgres",
  # En Docker el host de la base es el servicio `db` (DB_HOST); en CI/local, localhost.
  hostname: System.get_env("DB_HOST", "localhost"),
  database: "eth_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :eth, EthWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "IggzXAV0zdHsN53T5/NX8HjdTnhs6hck4zWLPKY7/p4A2waivAo1cSzu3DeG6trt",
  server: false

# Tests sin red (RNF-3.8): todo request a ESI pasa por stubs de Req.Test; un request
# sin stub hace fallar el test.
config :eth, Eth.Esi.Client, req_options: [plug: {Req.Test, Eth.Esi.Client}]

# En tests los procesos de fondo (mercado, estado de TQ, limpieza) no arrancan solos:
# cada test levanta lo que necesita.
config :eth, :start_workers, false

# Ventana de downtime vacía: los tests no dependen de la hora a la que corren
# (la ventana real se prueba como función pura). Backoff corto para tests rápidos.
config :eth, Eth.GameRules,
  downtime_window_utc: {~T[00:00:00], ~T[00:00:00]},
  backoff_base_ms: 50,
  poll_jitter_ms: 0..0

# In test we don't send emails
config :eth, Eth.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
