# Arquitectura

EVE Trade Hunter es una aplicación Phoenix LiveView autoalojada: un operador, N
personajes y el modo invitado (ERS §2.3). Los datos **universales** (mercado, SDE,
radar) viven en memoria (ETS y `persistent_term`); la **personalización** (impuestos,
capital, bodega, ruta del piloto) se aplica en tiempo de consulta. PostgreSQL guarda
solo lo que tiene que sobrevivir: personajes, ajustes, historial de precios, viajes,
línea base del radar y eventos.

Detalle normativo en el ERS §3 (arquitectura) y §8 (algoritmos). Este documento es el
mapa para orientarse en el código.

## Flujo de datos

```text
ESI (mercado, historial, precios)          zKillboard R2Z2 (kills)      EVE SSO
        │                                         │                        │
        ▼                                         ▼                        ▼
Eth.Esi.Client ── Eth.Esi.Budget          Eth.Threat.R2Z2 → Radar   Eth.Characters.Session
        │   (rate/error limit, pausas)            │  (mapa de calor)       (contexto del piloto)
        ▼                                         │                        │
RegionPoller / StructurePoller                    │                        │
        │  tablas de órdenes por fuente (ETS)     │                        │
        ▼  "market:snapshots"                     │                        │
Eth.Engine.Coordinator ── resúmenes ── evaluadores                          │
        │  tablas de oportunidades versionadas    │                        │
        ▼  "engine:opportunities"                 ▼                        ▼
Eth.Engine.query / station_query / order_query ◄── riesgo de ruta ◄── piloto
        │  (personalización por consulta)
        ▼
LiveViews: tablón (/, /orders, /station), viaje (/run), Centro de control, Ajustes
```

1. Los **pollers** descargan el mercado de cada región (y de cada estructura seguida)
   respetando `Expires`, ETag y el presupuesto de ESI, y publican una tabla ETS nueva por
   fuente con swap atómico de generación (RF-1.5).
2. El **coordinador del motor** agrupa los snapshots nuevos (debounce de 2 s, intervalo
   mínimo `:engine_min_interval_ms`), recalcula los resúmenes de las fuentes que
   cambiaron y evalúa las tres familias. Publica tablas nuevas y anuncia la versión.
   Entre una evaluación y otra conserva en su estado el momento de aparición de cada
   oportunidad (`seen`, RF-6.14), que estampa en las nuevas.
3. Cada **LiveView** vuelve a consultar al recibir el anuncio. La consulta personaliza
   con el contexto del piloto y el radar, filtra, ordena y devuelve a lo sumo 200 filas.

Ver [motor.md](motor.md) para el detalle de la evaluación y la consulta.

## Árbol de supervisión

`Eth.Application` (`one_for_one`). En los tests los procesos de fondo no arrancan
(`config :eth, :start_workers`): cada test levanta lo que necesita con
`start_supervised!/1`.

```text
Eth.Supervisor
├── EthWeb.Telemetry
├── Eth.Repo
├── DNSCluster                       (sin uso: no hay clúster)
├── Phoenix.PubSub (Eth.PubSub)
├── Finch (Eth.Finch)                pool de ESI: acota la concurrencia global
├── Eth.Vault                        Cloak: cifra los refresh tokens
├── Eth.Esi.Budget                   dueño de la tabla de presupuesto
│   ── procesos de fondo ──
├── Eth.Metrics                      métricas de la última hora y pestañas conectadas
├── Eth.GameRules.Overrides          publica overrides de reglas y parámetros
├── Eth.Events.Pruner                limpia el registro de eventos
├── Eth.Esi.ServerStatus             estado de Tranquility y downtime
├── Eth.Sde.Store                    descarga y carga el SDE
├── Eth.Market.Supervisor            (rest_for_one)
│   ├── TableOwner                   dueño estable de las tablas de órdenes
│   ├── Registry · TaskSupervisor
│   ├── RegionSupervisor → RegionPoller (uno por región)
│   ├── RegionManager                descubre regiones y arranca pollers
│   ├── SnapshotSaver                guarda snapshots (solo en vivo)
│   ├── Prices                       /markets/prices
│   ├── History                      historial a demanda (≤ 250 req/min)
│   ├── StructureSupervisor → StructurePoller (uno por estructura)
│   └── StructureManager             lista pública, acceso por personaje
├── Eth.Threat.Supervisor
│   ├── TaskSupervisor
│   ├── Baseline                     kills y saltos por hora (ESI)
│   ├── Radar                        mapa de calor en vivo
│   └── R2Z2 o ReplayFeed            feed de kills (según ETH_KILLFEED / Replay)
├── Eth.Engine.Supervisor            (rest_for_one)
│   ├── TaskSupervisor
│   └── Coordinator                  evaluación y versionado
├── Eth.Characters.Supervisor        (rest_for_one)
│   ├── Registry
│   ├── SessionSupervisor → Session  (una por personaje: tokens y contexto)
│   └── Task                         arranca las sesiones guardadas
├── Eth.Tracking.Supervisor          (rest_for_one)
│   ├── Registry · TaskSupervisor
│   ├── RunSupervisor → RunMonitor   (uno por viaje activo o sin reconciliar)
│   └── Task                         restaura los viajes al arrancar
├── Eth.Notifications.Dispatcher     alertas con enfriamiento
├── Eth.Characters.OrderWatch        órdenes propias superadas
└── EthWeb.Endpoint
```

Reglas de diseño (CLAUDE.md): el dominio es puro y los GenServers solo orquestan; nada
bloquea un GenServer (HTTP y cálculos pesados van en un `Task.Supervisor`); las tablas
ETS tienen un dueño estable.

## Contextos

| Contexto | Código | Qué hace |
|---|---|---|
| ESI | `lib/eth/esi` | Único cliente de ESI (`Eth.Esi.Client`): caché, ETag, rate y error limit, pausas. |
| SSO | `lib/eth/sso` | Estrategia Ueberauth de EVE, JWT/JWKS, scopes. |
| SDE | `lib/eth/sde` | Descarga, procesa y consulta los datos estáticos (en `persistent_term`); `Galaxy` arma la geometría del mapa del Centro de control (RF-8.2). |
| Ruteo | `lib/eth/routing` | Grafo, matrices de distancia, modos Rápida/Segura/Evasiva. |
| Mercado | `lib/eth/market` | Pollers, tablas de órdenes, estructuras, precios, historial. |
| Radar | `lib/eth/threat` | Feed de kills, línea base, detección y clasificación de amenazas. |
| Motor | `lib/eth/engine` | Evaluación universal, familias, personalización, anti-scam, scoring. |
| Personajes | `lib/eth/characters` | Sesiones, contexto del piloto, perfiles de nave, órdenes propias. |
| Viajes | `lib/eth/tracking` | Viaje activo, etapas, reconciliación, registro del cazador. |
| Operador | `lib/eth/accounts.ex` | Ajustes del operador (reglas, radar, alertas, parámetros del motor). |
| Reglas | `lib/eth/game_rules*` | Reglas del juego y parámetros calibrables, con overrides. |
| Otros | `lib/eth/{notifications,metrics,events,config_transfer,clock}*` | Alertas, métricas, registro de eventos, respaldo, reloj inyectable. |

La web (`lib/eth_web`) usa solo las APIs públicas de estos contextos: ningún LiveView
toca ETS ni `Repo` directamente.

## Tablas ETS

| Tabla | Dueño | Contenido |
|---|---|---|
| `:eth_orders` (una por fuente) + `:eth_market_catalog` | `Market.TableOwner` | Órdenes de cada región o estructura, con swap por generación. |
| `:eth_engine_summaries` | `Engine.Coordinator` | Mejores precios por `{fuente, tipo}` para el screening. |
| `:eth_opportunities*` + `:eth_opportunities_catalog` | `Engine.Coordinator` | Oportunidades de cada familia, versionadas. |
| `:eth_history_stats` | `Market.History` | Estadísticas de historial por `{región, tipo}`. |
| `:eth_prices` | `Market.Prices` | Precios de referencia globales. |
| `:eth_structure_access` | `Market.StructureManager` | Acceso de cada personaje a cada estructura. |
| `:eth_threat_heat` | `Threat.Radar` | Estado de cada sistema con kills en la ventana. |
| `:eth_threat_baseline` | `Threat.Baseline` | λ y riesgo base por sistema. |
| `:eth_esi_budget` | `Esi.Budget` | Presupuesto por grupo, error limit y pausas. |
| `:eth_server_status` | `Esi.ServerStatus` | Estado de Tranquility. |
| `:eth_sde_status` | `Sde.Store` | Estado de la carga del SDE. |
| `:eth_game_rule_overrides` | `GameRules.Overrides` | Overrides publicados (reglas, radar, motor). |
| `:eth_metrics` | `Metrics` | Contadores por minuto y pestañas conectadas. |

`persistent_term` se usa solo para el SDE, las matrices de distancia y la configuración
de `Eth.GameRules`.

## Tópicos PubSub

| Tópico | Mensajes |
|---|---|
| `market:snapshots` | `{:snapshot, fuente, generación}`: una fuente publicó datos nuevos. |
| `market:region:<id>` · `market:structure:<id>` | Cambios de una fuente. |
| `market:status` | Estado de los pollers; `{:esi_paused, ...}` / `:esi_resumed`. |
| `market:history` | `{:history_updated, n}`: llegaron estadísticas nuevas. |
| `engine:opportunities` | `{:opportunities_updated, meta}`: versión nueva del motor. |
| `threat:heatmap` · `threat:kills` | Cambios del mapa de calor; kills relevantes. |
| `character:<id>` | Contexto del personaje actualizado, `:relogin`. |
| `run:<id>` | Eventos del viaje activo de un personaje. |
| `notifications` | `{:alert, alerta}` ya filtrada por enfriamiento. |
| `sde:status` · `system:status` · `system:events` | SDE, estado del servidor, registro de eventos. |

## Base de datos

| Tabla | Para qué |
|---|---|
| `operators` | Operador único y sus ajustes (`settings`: reglas, radar, alertas, `engine`). |
| `characters` | Personajes, scopes y refresh token cifrado. |
| `ship_profiles` | Perfiles de bodega y clase de evasión por nave o casco. |
| `structures` · `structure_access` | Estructuras conocidas, seguidas, broker fee, acceso por personaje. |
| `market_history_stats` | Historial de precios procesado (sobrevive a reinicios). |
| `scam_reports` | Falsos positivos del escudo reportados por el piloto. |
| `system_activity_hourly` · `system_activity_samples` | Línea base del radar (30 días). |
| `trade_runs` · `wallet_transactions` | Viajes y transacciones de la billetera para reconciliar. |
| `system_events` | Registro de eventos del Centro de control. |
| `app_state` | Claves sueltas (por ejemplo el cursor del feed R2Z2). |

Los datos regenerables (SDE procesado, matrices de ruteo, snapshots del mercado, kills
de la ventana, grabaciones de Replay) viven en el directorio de datos (`Eth.Storage`,
volumen propio), nunca en la base ni en git.

## Capa web

- **LiveViews** (`lib/eth_web/live`): `HunterLive` (Directo, `/`), `OrderLive`
  (`/orders`), `StationLive` (`/station`), `RunLive` (`/run`), `ControlLive`
  (`/control/<pestaña>`), `SettingsLive` (`/settings/<pestaña>`) y `DocsLive` (`/docs`).
- **Hooks de montaje** (en todas las vistas): `PilotHook` (piloto activo),
  `RadarHook` (estado del radar en la cabecera), `AlertsHook` (toasts y notificaciones del
  navegador), `ViewersHook` (cuenta las pestañas abiertas).
- **Componentes**: `EthWeb.UI` (sistema visual: paneles, instrumentos, tooltips, `term/1`,
  `spark/1`, `type_icon/1`), `EthWeb.TradingComponents` (tablón, filtros, ficha),
  `EthWeb.Layouts` y `CoreComponents`.
- **Mapa del Centro de control** (RF-8.2): `Eth.Sde.Galaxy` da la geometría y
  `EthWeb.GalaxyMap` los cálculos de presentación (calor, oportunidades por lugar, pilotos,
  búsqueda); `ControlLive` dibuja el SVG en el servidor y el hook `.MapCanvas` maneja zoom,
  arrastre, tooltip y pantalla completa del lado del cliente. `ControlLive` escucha
  `engine:opportunities` y, solo con el mapa a la vista, cuenta las oportunidades por lugar;
  también escucha `run:<personaje>` y dibuja el camino que le falta a cada viaje activo
  (`Eth.Tracking.remaining_path/1`, que se lo pide al `RunMonitor`).
- **Documentación y glosario**: `EthWeb.Docs` (páginas y temas), `EthWeb.DocsPages`
  (plantillas HEEx con valores vigentes de las reglas) y `EthWeb.Glossary`.
- **JS**: solo colocated hooks; el CSP es estricto (sin `unsafe-inline`, `EthWeb.CSP`).
