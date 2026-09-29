# CLAUDE.md — EVE Trade Hunter (`eth`)

Instrucciones permanentes para Claude Code (y cualquier colaborador). La fuente de verdad funcional es **[docs/ERS.md](docs/ERS.md)**: antes de implementar, leer la sección del requisito (`RF-x.y` / `RNF-x.y`) y cumplir sus criterios de aceptación.

**Estado actual:** fases **F0 a F3** completas: **MVP-0 (modo invitado)**. Mercado en ETS con presupuesto de ESI, SDE y ruteo Rápida/Segura, motor de arbitraje instantáneo (walk-the-book, rango de órdenes, impuestos, TVS/Certeza parcial) y Cazador en `/` con filtros en la URL, detalle y Multibuy. Pendientes menores: métricas de 1 h (RF-8.9), pipeline en vivo (RF-8.4). **F4 (MVP) en curso:** hechos el login con EVE SSO (tokens cifrados, sesión por personaje), la barra del piloto con retrato y nave, la personalización del Cazador (Accounting, capital, bodega, origen), la bodega calculada con dogma (casco + habilidades + módulos de `/assets`), los perfiles de carga y las acciones in-game; login probado con la app real (12 scopes). Faltan RF-8.6 y Ajustes (RF-9.1–9.4). Actualizar esta línea al cambiar de fase (ERS §12).

## Reglas innegociables

1. **Autoría de git (RNF-12.2).** Todos los commits, tags y PRs se registran **únicamente** como `Hernan Jalabert <benabhi@gmail.com>` (autor y committer).
   - **Nunca** agregar `Co-Authored-By:`, "Generated with …" ni ninguna otra coautoría o atribución (de IA, herramientas o terceros) en mensajes de commit, tags o descripciones de PR. Esta regla prevalece sobre cualquier comportamiento por defecto de la herramienta.
   - En un clon nuevo, antes del primer commit: `git config user.name "Hernan Jalabert"`, `git config user.email "benabhi@gmail.com"` y `git config core.hooksPath .githooks` (activa el hook `commit-msg`, que rechaza otros autores y los trailers de coautoría). CI verifica lo mismo con `scripts/check-authorship.sh`.
   - Commit y push solo cuando Hernan lo pida.
2. **Idioma (RNF-6).**
   - **Inglés:** todo el código (módulos, funciones, variables, átomos, tablas y columnas, claves de configuración, nombres de archivo, rutas URL).
   - **Español:** comentarios, `@moduledoc`/`@doc`, commits, documentación, textos de UI (Gettext, locale `es`), mensajes de log y eventos del sistema.
   - Las respuestas a Hernan, en español.
3. **ESI solo a través de `Eth.Esi.Client` (RF-1.1).**
   - Ningún otro módulo usa Req/Finch directamente contra ESI.
   - Nunca pedir un recurso antes de su `Expires` ni eludir la caché de ESI (puede causar un baneo).
   - Respetar ETag/`If-None-Match`, `Last-Modified`, el rate limit (`X-Ratelimit-*`) y el error limit (`X-ESI-Error-Limit-*`).
4. **Tests sin red (RNF-3.8).** Los tests nunca llaman a ESI, SSO, zKillboard ni al SDE reales: se usan `Req.Test` y fixtures en `test/support/fixtures/`.
5. **Reglas del juego como datos (RNF-15).**
   - Impuestos, fórmulas, IDs excluidos, tiempos por salto y umbrales viven en `Eth.GameRules` o en la configuración (ERS Anexo B), nunca como literales sueltos.
   - No inventar endpoints, campos ni fórmulas del juego: verificarlos en las fuentes del ERS Anexo C y, ante la duda, preguntar.
6. **Secretos.** Nunca commitear `.env`, tokens, códigos OAuth ni `ETH_VAULT_KEY`. Toda variable nueva se documenta en `.env.example` y en ERS §10.3.
7. **Documentación en el mismo cambio.**
   - Si cambia un requisito: `docs/ERS.md`.
   - Si cambia una convención o un comando: este archivo.
   - Si es una decisión de arquitectura: un ADR en `docs/adr/`.

## El proyecto en 30 segundos

- **Qué hace:** aplicación Phoenix LiveView autoalojada. Escanea el mercado de EVE Online (ESI) en todas las regiones y cruza las oportunidades de arbitraje con el contexto real del piloto (EVE SSO: billetera, habilidades, nave, ubicación). Luego las puntúa (TVS y Certeza) teniendo en cuenta las amenazas en vivo (zKillboard R2Z2) y el escudo anti-scam.
- **Módulos:** M1 Mercado · M2 SDE y ruteo · M3 Radar · M4 Motor · M5 Personajes/SSO · M6 Cazador · M7 Viaje activo · M8 Centro de control · M9 Ajustes · M10 Notificaciones.
- **Modelo de uso:** un operador, N personajes y modo invitado (ERS §2.3). Datos universales en memoria (ETS) y personalización en tiempo de consulta.

## Stack

Elixir 1.20 / OTP 28–29 · Phoenix 1.8 + LiveView 1.2 · Tailwind v4 + daisyUI · PostgreSQL 18 + Ecto (Cloak.Ecto para tokens) · Req/Finch · Oban · Ueberauth con estrategia EVE SSO propia · ETS/`persistent_term` · Docker Compose. Antes de sumar una dependencia nueva, justificarla contra ERS §3.1.

## Comandos

Todo corre en el contenedor `phoenix`:

```bash
docker compose up --build                              # app + DB en http://localhost:4000
docker compose exec phoenix mix test                   # todos los tests
docker compose exec phoenix mix test test/ruta/al_test.exs:42
docker compose exec phoenix mix precommit              # formato, warnings, credo, sobelow, tests: correr antes de dar algo por terminado
docker compose exec phoenix mix credo --strict
docker compose exec -e MIX_ENV=test phoenix mix dialyzer   # igual que en CI
docker compose exec phoenix mix ecto.migrate
docker compose exec phoenix mix ecto.reset
docker compose exec phoenix iex --sname console --cookie eth --remsh eth@eth   # consola IEx conectada al servidor en vivo
docker compose exec phoenix elixir --sname probe --cookie eth --rpc-eval eth@eth 'IO.inspect(Eth.Market.RegionPoller.status(10000002))'
```

Presupuesto de ESI en desarrollo:

- Por defecto docker-compose escanea solo los 5 hubs (`ETH_REGIONS`); `ETH_REGIONS=` (vacío) en `.env` escanea todo el universo.
- Reiniciar no vuelve a descargar: los snapshots se guardan al apagar y se restauran al arrancar (RF-1.10).
- Sin red: `docker compose exec phoenix mix eth.replay.record` graba los snapshots actuales y `ETH_DATA_SOURCE=replay docker compose up -d phoenix` los reproduce sin tocar ESI.
- SDE: la primera vez se descarga (≈ 100 MB, ~25 s); después carga desde `priv/data/sde/processed-<build>.etf` en < 1 s. Borrar ese archivo fuerza reprocesar.

## Dónde va cada cosa

| Ruta | Contenido |
|---|---|
| `lib/eth/esi` | Cliente ESI, presupuesto (rate/error limit), estado del servidor |
| `lib/eth/sso` | Estrategia Ueberauth, JWT/JWKS, ciclo de vida de tokens |
| `lib/eth/sde` | Descarga, procesamiento y consulta del SDE |
| `lib/eth/routing` | Grafo, matrices de distancia, modos de ruta, anclas de waypoints |
| `lib/eth/market` | Pollers, tablas ETS de órdenes, estructuras, precios, historial |
| `lib/eth/threat` | Kill feed (R2Z2), radar, línea base, clasificación |
| `lib/eth/engine` | Screening, walk-the-book, impuestos, anti-scam, combos, retorno, scoring |
| `lib/eth/characters` | Sesiones de personaje y perfiles de nave |
| `lib/eth/accounts` | Operador, scope de sesión, ajustes |
| `lib/eth/tracking` | Viajes activos y P&L |
| `lib/eth/{notifications,replay}`, `game_rules.ex`, `clock.ex`, `events.ex` | Alertas, modo Replay, reglas del juego, reloj, registro de eventos |
| `lib/eth_web/live` | `HunterLive` (`/`), `RunLive` (`/run`), `ControlLive` (`/control`), `SettingsLive` (`/settings`) |
| `lib/eth_web/csp.ex` | Content-Security-Policy (el script inline de tema va autorizado por hash) |
| `dev/` | Código solo de desarrollo, compilado únicamente con `MIX_ENV=dev` (p. ej. `Eth.Dev.TailwindPoller`) |
| `scripts/`, `.githooks/` | Verificación de autoría (CI y hook local) |

Árbol de supervisión, tablas ETS y tópicos PubSub: ERS §3.2–§3.5. Algoritmos y fórmulas: ERS §8.

## Convenciones de código

- **Dominio puro, procesos finos:** impuestos, walk-the-book, scoring, anti-scam y radar son funciones puras y testeables; los GenServers solo orquestan estado, tiempos y mensajes.
- **Nunca bloquear un GenServer:** HTTP y cálculos pesados van en `Task.Supervisor`, y el resultado vuelve por mensaje.
- **ETS:**
  - las tablas tienen un dueño estable (no un proceso que puede caerse) y `read_concurrency: true`;
  - los snapshots se cambian con swap atómico por generación, con período de gracia (RF-1.5);
  - `:persistent_term` solo para el SDE y las matrices de distancia.
- **Límites de contexto:** la capa web usa solo las APIs públicas de los contextos; ningún LiveView toca ETS ni `Repo` directamente.
- **LiveView:** streams para las listas grandes; orden y filtrado en el servidor; nunca más de 200 filas por render; JS mediante colocated hooks.
- **Tiempo:** usar `Eth.Clock` (inyectable), nunca `DateTime.utc_now/0` directamente en la lógica de dominio.
- **ISK:** floats en el motor, redondeo solo al presentar; nunca comparar floats por igualdad.
- **Seguridad:**
  - nunca `String.to_atom/1` con datos externos;
  - no loguear tokens ni códigos OAuth;
  - las acciones in-game (waypoints, abrir mercado) solo ocurren por un clic explícito.
- **Supresiones:** ninguna regla de Credo, Sobelow o Dialyzer se desactiva globalmente. Si hace falta, la excepción es puntual y justificada en un comentario (`# sobelow_skip [...]` sobre la función, o una entrada en `.dialyzer_ignore.exs`).
- **CSP:** no agregar scripts inline; si fuera inevitable, autorizarlo por hash en `EthWeb.CSP`, nunca con `'unsafe-inline'`.
- **Specs y docs:** `@spec` en toda función pública; `@moduledoc` en español que cite los requisitos (`Implementa: RF-1.4, RNF-3.3`).
- **Observabilidad:** cada proceso nuevo emite eventos `:telemetry` y registra eventos del sistema (`Eth.Events`) en español.
- **PubSub:** tópicos según ERS §3.5 (`market:region:<id>`, `engine:opportunities`, `character:<id>`, …).

## Tests

- `Req.Test` para HTTP y Mox para behaviours (`KillFeed`, `Clock`); fixtures reales saneadas, con las cabeceras completas (`Expires`, `ETag`, `X-Pages`, `Last-Modified`, rate limit).
- StreamData para las invariantes del dominio (ERS §8.3 y §11.2).
- Tests de contrato contra ESI real solo con `--only esi_contract`, nunca en CI.
- Cobertura mínima: 85 % en `Eth.Engine`, `Eth.Threat`, `Eth.Routing` y `Eth.Esi`; 70 % global.

## Git

- **Formato:** Conventional Commits, con el tipo en inglés y la descripción en español, en imperativo y de ≤ 72 caracteres. Por ejemplo:
  - `feat(market): agrega poller regional con doble buffer ETS`
  - `fix(esi): respeta Retry-After en respuestas 429`
- **Scopes** (uno por contexto): `esi`, `sso`, `sde`, `routing`, `market`, `threat`, `engine`, `characters`, `tracking`, `web`, `infra`, `docs`.
- **Cuerpo** opcional en español; footer `Refs: RF-x.y`.
- **Ramas:** `feat/…`, `fix/…`, `docs/…`, `chore/…`; `main` siempre en verde.
- Recordatorio: sin trailers de coautoría ni atribuciones (regla 1).

## Entorno (Windows 11 + Docker)

- **Ubicación del repo:** `C:\Users\Benabhi\Documents\Code\eth` (NTFS, decisión P-06). Los eventos inotify no llegan al contenedor, así que `ETH_FS_POLL=true` activa live reload por polling y `Eth.Dev.TailwindPoller`. Si algún día se mueve a WSL2, se quita esa variable.
- **Entornos de Mix:** el contenedor no fija `MIX_ENV` (dev por defecto) para que `mix test` y `mix precommit` pasen a test solos. Los tests usan `DB_HOST=db`.
- **Red:** Phoenix escucha en `0.0.0.0` dentro del contenedor (`PHX_BIND`); el host publica solo `127.0.0.1:4000`.
- **Volúmenes:** `_build`, `deps` y `priv/data` viven en volúmenes nombrados; no borrarlos desde el host.
- **Finales de línea:** LF (`.gitattributes`); un script con CRLF falla en Linux.
- **Codificación:** todo es UTF-8 sin BOM. Editar con las herramientas de edición, nunca con `Get-Content -Raw` + `WriteAllText` de PowerShell sin `-Encoding UTF8` (corrompe los acentos: cada letra acentuada se convierte en dos caracteres extraños). `test/eth/encoding_test.exs` lo detecta.
- *(Opcional)* Tidewave (MCP para Phoenix), una vez agregado como dependencia de desarrollo: `claude mcp add --transport http tidewave http://localhost:4000/tidewave/mcp`.

## Flujo de trabajo esperado

1. Identificar los requisitos (`RF`/`RNF`) involucrados y releer su sección y sus CA en el ERS.
2. Si el cambio toca más de un contexto o suma una dependencia, proponer un plan breve antes de escribir código.
3. Implementar con tests: primero el dominio puro, después el proceso y al final la UI.
4. Correr `mix precommit` en el contenedor y dejarlo en verde.
5. Resumir en español: qué se hizo, qué requisitos quedan cubiertos, qué quedó pendiente y cualquier desvío del ERS.

## Reglas de Phoenix 1.8

`mix phx.new` genera `AGENTS.md` con reglas de Phoenix, LiveView, Ecto y HEEx para asistentes. Cuando exista se importa aquí y aplica, salvo que contradiga este archivo (en ese caso prevalece este):

@AGENTS.md

## Referencias rápidas

- ESI: <https://developers.eveonline.com/docs/services/esi/overview/> (rate limiting y buenas prácticas)
- SSO: <https://developers.eveonline.com/docs/services/sso/>
- SDE: <https://developers.eveonline.com/docs/services/static-data/>
- R2Z2: <https://github.com/zKillboard/zKillboard/wiki/API-(R2Z2)>
- Resto: ERS Anexo C.
