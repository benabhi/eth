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

# EVE SSO (RF-5.1, RF-5.2, ERS §6.2). Endpoints verificados en
# /.well-known/oauth-authorization-server (2026-09-29). Credenciales en runtime.exs.
config :eth, Eth.Sso,
  authorize_url: "https://login.eveonline.com/v2/oauth/authorize",
  token_url: "https://login.eveonline.com/v2/oauth/token",
  revoke_url: "https://login.eveonline.com/v2/oauth/revoke",
  jwks_url: "https://login.eveonline.com/oauth/jwks",
  issuers: ["https://login.eveonline.com", "login.eveonline.com"],
  scopes: ~w(
    publicData
    esi-markets.structure_markets.v1
    esi-universe.read_structures.v1
    esi-wallet.read_character_wallet.v1
    esi-skills.read_skills.v1
    esi-characters.read_standings.v1
    esi-location.read_location.v1
    esi-location.read_ship_type.v1
    esi-ui.write_waypoint.v1
    esi-location.read_online.v1
    esi-ui.open_window.v1
    esi-assets.read_assets.v1
    esi-markets.read_character_orders.v1
  )

config :ueberauth, Ueberauth, providers: [eve: {Eth.Sso.Strategy, []}]

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
  # Reinicio en caliente (RF-1.10): guardar cada 10 min; restaurar si tiene < 15 min.
  snapshot_save_interval_ms: 600_000,
  warm_restart_max_age_min: 15,
  backoff_base_ms: 2_000,
  backoff_max_ms: 300_000,
  circuit_breaker_failures: 5,
  circuit_breaker_open_ms: 600_000,
  # Frescura (RF-4.9): minutos para degradado / viejo / excluido
  staleness_minutes: {5, 15, 30},
  # SDE (RF-2.1): URL base y chequeo de builds nuevos cada 6 h.
  sde_base_url: "https://developers.eveonline.com/static-data",
  sde_check_interval_ms: 21_600_000,
  # Ruteo (RF-2.4): regiones fuera del grafo (Pochven y la región de Zarzakh, con
  # mecánicas de gates especiales) y sistema raíz de la componente conexa principal (Jita).
  excluded_route_region_ids: [10_000_070, 10_001_000],
  route_root_system_id: 30_000_142,
  # Umbral de highsec sobre la seguridad real (se muestra ≥ 0.5)
  highsec_min_security: 0.45,
  # Impuestos (verificados 2026-09-29, Anexo B.1): sales tax = base × (1 − 0,11 × Accounting).
  # Fecha de verificación que muestra Ajustes → Reglas (RF-9.4).
  rules_verified_on: ~D[2026-09-29],
  sales_tax_base: 0.075,
  accounting_reduction_per_level: 0.11,
  broker_fee_base: 0.03,
  broker_relations_reduction_per_level: 0.003,
  broker_faction_standing_coef: 0.0003,
  broker_corp_standing_coef: 0.0002,
  # Motor (RF-4.x, Anexo B.7)
  guest_accounting_level: 4,
  # Broker Relations del modo invitado (station trading, RF-4.16), con standings neutros.
  guest_broker_relations_level: 4,
  min_profit_isk: 1_000_000,
  min_unit_margin_isk: 0.01,
  max_universal_opportunities: 5_000,
  # Tiempo de viaje (RF-2.7): segundos por salto por clase de nave y por parada.
  jump_seconds: %{
    shuttle: 15,
    blockade_runner: 25,
    deep_space_transport: 40,
    industrial: 50,
    freighter: 90,
    other: 45
  },
  stop_overhead_s: 180,
  guest_ship_class: :industrial,
  # Bodega por defecto del modo invitado (Iteron Mark V con módulos de carga). Sin este
  # tope el ranking lo dominan cargas imposibles (capitales, millones de m³).
  guest_cargo_m3: 38_500,
  # Contexto del piloto (RF-5.5, RF-5.6, RF-5.8). Accounting: type_id 16622 del SDE.
  accounting_skill_id: 16_622,
  # Órdenes de mercado (F9, P-12 verificada el 2026-09-29):
  # - precios con 4 cifras significativas como máximo (blog de CCP "Broker Relations",
  #   2020-02-24) y 0,01 ISK de precisión;
  # - relist = BR × max(0, V2 − V1) + (1 − RD) × BR × V2, RD = 50 % + 6 % × Advanced
  #   Broker Relations (descripción de la habilidad 16597 en el SDE 3552227);
  # - límite de órdenes = 5 + 4·Trade + 8·Retail + 16·Wholesale + 32·Tycoon (SDE);
  # - el SDE vigente no tiene Margin Trading: el escrow de una compra es el 100 %.
  order_price_significant_digits: 4,
  broker_relations_skill_id: 3_446,
  advanced_broker_relations_skill_id: 16_597,
  relist_discount_base: 0.5,
  relist_discount_per_level: 0.06,
  order_limit_base: 5,
  order_limit_per_level: %{3_443 => 4, 3_444 => 8, 16_596 => 16, 18_580 => 32},
  buy_order_escrow_ratio: 1.0,
  # Station trading (RF-4.16): estaciones de los 5 hubs (verificadas en el SDE).
  station_trading_location_ids: [60_003_760, 60_008_494, 60_011_866, 60_004_588, 60_005_686],
  # Parámetros calibrables del station trading (Anexo B.7):
  # - screen_margin: margen neto mínimo con las comisiones más bajas posibles (universal);
  # - participation: fracción del volumen diario (7 d) que se apunta a mover por día;
  # - competition_band / competition_half: órdenes dentro de ±banda del precio sugerido;
  #   con `competition_half` órdenes la Certeza por competencia es 0,5;
  # - book_depth: órdenes guardadas por lado; history_demand_max: pares por evaluación;
  # - max_price_to_median: realismo de los precios sugeridos frente a la mediana.
  station_trading: %{
    screen_margin: 0.02,
    min_margin: 0.05,
    min_daily_volume: 10,
    participation: 0.1,
    competition_band: 0.05,
    competition_half: 10,
    book_depth: 25,
    # Precios sugeridos dentro de ×2 / ÷2 de la mediana de 7 días (si no, el margen es
    # ilusorio: una venta a un precio que nadie paga).
    max_price_to_median: 2.0,
    history_demand_max: 2_000
  },
  # Trading por órdenes entre estaciones (RF-4.1, Listado y compra por orden), calibrable:
  # - screen_margin / min_margin: margen neto mínimo universal (comisiones mínimas) y
  #   personal por defecto;
  # - max_days: la cantidad se acota para ejecutarse en a lo sumo estos días (con la
  #   participación de `:station_trading`); max_origins / max_destinations: candidatos
  #   por tipo y hub; book_depth: órdenes guardadas por lado.
  order_trading: %{
    screen_margin: 0.03,
    min_margin: 0.05,
    max_days: 7,
    max_origins: 5,
    max_destinations: 4,
    book_depth: 15
  },
  # Broker fee mínimo posible en una estación NPC (BR V y standings 10/10): cota del
  # screening universal.
  min_broker_fee: 0.01,
  # Capital disponible = saldo × porcentaje − reserva fija (RF-5.5, calibrable).
  capital_wallet_share: 1.0,
  capital_reserve_isk: 0,
  # Clase de evasión sugerida por grupo del SDE (verificado en el SDE 3552227): 31 Shuttle,
  # 1202 Blockade Runner, 380 Deep Space Transport, 28 Hauler, 513 Freighter,
  # 902 Jump Freighter. El resto: :other.
  ship_group_evasion_classes: %{
    31 => :shuttle,
    1202 => :blockade_runner,
    380 => :deep_space_transport,
    28 => :industrial,
    513 => :freighter,
    902 => :freighter
  },
  # Bodega calculada (RF-5.8): atributos dogma del SDE (verificados en el SDE 3552227).
  # 38 = capacity (bodega general, stackable); 280 = skillLevel.
  dogma_capacity_attribute_id: 38,
  dogma_skill_level_attribute_id: 280,
  # Flags de ESI /assets de los módulos montados en una nave (OpenAPI de ESI).
  fitted_location_flag_prefixes: ~w(HiSlot MedSlot LoSlot RigSlot SubSystemSlot),
  # Certeza de acceso (ERS §8.9, AS-8): NPC 1; estructura privada con acceso verificado
  # 0,95; pública 0,9; sin verificar o sin acceso 0,5.
  access_certainty: %{private_verified: 0.95, public: 0.9, unverified: 0.5},
  # TVS y Certeza (ERS §8.9)
  tvs_weights: %{isk_per_hour: 0.40, profit: 0.25, roi: 0.15, liquidity: 0.20},
  tvs_refs: %{isk_per_hour: 150_000_000, profit: 100_000_000, roi: 0.25},
  order_tau_min: 180,
  # Liquidez neutra mientras no hay historial del tipo (RF-4.7).
  default_liquidity: 0.5,
  # Liquidez (RF-4.7): índice 1 si la cantidad no supera el volumen de `full_at_days`
  # días; ilíquido con menos de `min_days_traded` días operados en 30.
  liquidity: %{full_at_days: 1, min_days_traded: 5},
  # Escudo anti-scam (ERS §8.7, calibrables). Mediana de 7 días si hubo al menos
  # `min_days_7d` días operados; si no, la de 30. Certeza por estado según §8.9.
  anti_scam: %{
    scam_bid_ratio: 3.0,
    suspicious_bid_ratio: 1.5,
    global_price_ratio: 5.0,
    origin_ask_ratio: 1.5,
    fresh_order_minutes: 120,
    min_days_traded: 3,
    min_days_7d: 3,
    no_history_max_roi: 1.0,
    certainty: %{ok: 1.0, no_history: 0.7, suspicious: 0.5, scam: 0.0}
  },
  # Downtime diario de Tranquility (UTC) (RF-1.8)
  downtime_window_utc: {~T[10:59:00], ~T[11:15:00]},
  status_poll_ms: 60_000,
  # Estructuras (RF-1.6): top de públicas por órdenes y sincronización horaria.
  structures_top: 30,
  structures_refresh_ms: 3_600_000,
  # Anti-spam de alertas (RF-10.3, Anexo B.7 notify.cooldown_min).
  notify_cooldown_min: 10,
  # Viaje activo (RF-7.2, RF-7.3, RF-7.5): fracción de la inversión o del ingreso que tiene
  # que moverse el saldo para inferir la compra o la venta; alertas de revalidación y
  # re-ruteo (Anexo B.7: run.revalidate_drop_pct / run.reroute_gain_pct); gracia de la
  # reconciliación tras el cierre.
  run: %{
    bought_share: 0.9,
    sold_share: 0.9,
    revalidate_drop: 0.10,
    reroute_gain: 0.10,
    reconcile_grace_min: 90
  },
  # Historial bajo demanda (RF-1.12, RNF-3.5): ESI admite 300 req/min; se deja margen.
  history_max_per_min: 250,
  history_concurrency: 4,
  # Agrupa los anuncios de estadísticas nuevas para no re-consultar el Cazador por cada una.
  history_announce_ms: 5_000,
  # Radar (RF-3.x, ERS §8.8). Categorías del SDE cuyos tipos guardan su grupo aunque no
  # estén en el mercado: 6 Ship, 7 Module (verificado en el SDE 3552227).
  radar_type_categories: [6, 7],
  radar: %{
    window_min: 15,
    half_life_min: 10,
    min_kills: 3,
    p_value: 0.01,
    # Multiplicadores de intensidad: víctima de transporte y kill en un stargate.
    hauler_weight: 1.5,
    gate_weight: 1.5,
    # Línea base: 14 días por franja horaria; con menos de 7, promedio del sistema.
    baseline_days: 14,
    baseline_min_days: 7,
    lambda_min: 0.05,
    # Prior de λ (kills por ventana) por banda cuando no hay datos del sistema.
    lambda_prior: %{highsec: 0.05, lowsec: 0.2, nullsec: 0.3},
    base_risk_max: 0.2,
    # Riesgo base por banda mientras no hay saltos muestreados (RF-3.7).
    base_risk_prior: %{highsec: 0.0005, lowsec: 0.01, nullsec: 0.02},
    # Suavizado del riesgo base: kills / (saltos + k) para sistemas con poco tráfico.
    base_risk_smoothing_jumps: 50,
    activity_retention_days: 30,
    # Sin kills del feed durante este tiempo: radar degradado (RF-3.8).
    feed_stale_s: 120,
    # Penalización de la Certeza por sistema low/null con el radar degradado.
    degraded_penalty: 0.97,
    max_alert_probability: 0.95
  },
  # Grupos del SDE (verificados en el SDE 3552227) para normalizar killmails (RF-3.2) y
  # clasificar amenazas (§8.8).
  radar_groups: %{
    # Hauler, Deep Space Transport, Blockade Runner, Freighter, Jump Freighter.
    transport: [28, 380, 1202, 513, 902],
    # Capsule, Shuttle, Corvette y fragatas.
    small: [29, 31, 237, 25, 324, 830, 831, 893, 1283, 1527],
    # Interdictor y Heavy Interdiction Cruiser.
    interdictor: [541, 894],
    smart_bomb: [72]
  },
  # CONCORD (corporación NPC 1000125): sus kills confirman un hauler_gank.
  concord_corporation_id: 1_000_125,
  # Modo Evasiva (RF-2.5): costo por sistema 1 + α × amenaza.
  evasive_alpha: 20,
  # Sistemas a evitar (RF-2.5): los define el operador en Ajustes → Radar.
  avoid_system_ids: [],
  # Matriz de vulnerabilidad por clase de nave (ERS Anexo B.8).
  vulnerability: %{
    freighter: %{
      gate_camp: 0.95,
      bubble_camp: 0.95,
      smartbomb_camp: 0.30,
      hauler_gank: 0.90,
      roaming: 0.60
    },
    industrial: %{
      gate_camp: 0.85,
      bubble_camp: 0.90,
      smartbomb_camp: 0.60,
      hauler_gank: 0.70,
      roaming: 0.50
    },
    deep_space_transport: %{
      gate_camp: 0.50,
      bubble_camp: 0.70,
      smartbomb_camp: 0.30,
      hauler_gank: 0.35,
      roaming: 0.25
    },
    blockade_runner: %{
      gate_camp: 0.20,
      bubble_camp: 0.45,
      smartbomb_camp: 0.40,
      hauler_gank: 0.15,
      roaming: 0.10
    },
    shuttle: %{
      gate_camp: 0.30,
      bubble_camp: 0.50,
      smartbomb_camp: 0.90,
      hauler_gank: 0.05,
      roaming: 0.20
    },
    other: %{
      gate_camp: 0.70,
      bubble_camp: 0.80,
      smartbomb_camp: 0.50,
      hauler_gank: 0.30,
      roaming: 0.40
    }
  }

# zKillboard R2Z2 (RF-3.1, ERS §6.3).
config :eth, Eth.Threat.R2Z2, base_url: "https://r2z2.zkillboard.com/ephemeral"

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
