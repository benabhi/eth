# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :eth,
  ecto_repos: [Eth.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :eth, EthWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: EthWeb.ErrorHTML, json: EthWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Eth.PubSub,
  live_view: [signing_salt: "BTOPEK3w"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :eth, Eth.Mailer, adapter: Swoosh.Adapters.Local

# Textos de UI en español por defecto (RNF-6.3).
config :eth, EthWeb.Gettext, default_locale: "es"

# Cliente ESI (RF-1.1, RNF-3). La fecha de compatibilidad es fija y se actualiza a propósito;
# ESI_COMPATIBILITY_DATE la sobreescribe en runtime.exs.
config :eth, Eth.Esi.Client,
  base_url: "https://esi.evetech.net",
  compatibility_date: "2026-09-01",
  receive_timeout: 30_000

# Reglas del juego y parámetros calibrables (ERS Anexo B). Nunca como literales en el código.
config :eth, Eth.GameRules,
  # Regiones de nivel N1 (hubs): The Forge, Domain, Sinq Laison, Heimatar, Metropolis
  hub_region_ids: [10_000_002, 10_000_043, 10_000_032, 10_000_030, 10_000_042],
  # Exclusiones de escaneo (Anexo B.4): Pochven y Mercado Global de PLEX.
  excluded_region_ids: [10_000_070, 19_000_001],
  # J-space (11000001–11000033) y abisal/especiales (≥ 12000000) por rango.
  excluded_region_id_from: 11_000_000,
  # Una región con al menos estas páginas en su último ciclo pasa a N2 (Activas).
  active_region_min_pages: 5,
  # Presupuesto de ESI
  error_limit_pause_at: 20,
  market_budget_group: "market-order",
  # Pollers (RF-1.3, RF-1.4)
  poll_jitter_ms: 1_000..5_000,
  pages_concurrency: 8,
  page_retries: 2,
  snapshot_grace_ms: 60_000,
  backoff_base_ms: 2_000,
  backoff_max_ms: 300_000,
  circuit_breaker_failures: 5,
  circuit_breaker_open_ms: 600_000,
  # Frescura (RF-4.9): minutos para degradado / viejo / excluido
  staleness_minutes: {5, 15, 30},
  # Downtime diario de Tranquility (UTC) (RF-1.8)
  downtime_window_utc: {~T[10:59:00], ~T[11:15:00]},
  status_poll_ms: 60_000

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  eth: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.3",
  eth: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
