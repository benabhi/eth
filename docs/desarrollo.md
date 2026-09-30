# Desarrollo

Guía para trabajar en el código. Las reglas del proyecto (autoría de git, idioma, ESI,
tests sin red, secretos) están en [`CLAUDE.md`](../CLAUDE.md) y son obligatorias; acá está
el cómo.

## Entorno

Todo corre en Docker; el código se monta desde el host.

```bash
docker compose up --build        # app + base en http://localhost:4000 (live reload)
```

- `.env` con `EVE_CLIENT_ID`, `EVE_CLIENT_SECRET` y `ETH_VAULT_KEY` (ver `.env.example`).
- Por defecto se escanea **todo el universo** (~2 GB de RAM). Para desarrollar con menos:
  `ETH_REGIONS=10000002,10000043,10000032,10000030,10000042` en `.env` (los 5 hubs).
- En Windows con el repo en NTFS, `ETH_FS_POLL=true` hace el live reload por polling.
- El live reload recompila el código pero **no** `config/*.exs`: después de cambiar la
  configuración o de agregar una migración, `docker compose exec phoenix mix
  ecto.migrate` y `docker compose restart phoenix`.
- Con el servidor corriendo, compilá o probá con `MIX_ENV=test` para no pisar el build de
  desarrollo: `docker compose exec -e MIX_ENV=test phoenix mix compile --warnings-as-errors`.

## Comandos

```bash
docker compose exec phoenix mix test                          # todos los tests
docker compose exec phoenix mix test test/eth/engine          # una carpeta
docker compose exec phoenix mix test test/ruta/al_test.exs:42 # un test
docker compose exec phoenix mix precommit                     # formato, warnings, Credo, Sobelow y tests
docker compose exec -e MIX_ENV=test phoenix mix dialyzer
docker compose exec phoenix mix test --cover
```

`mix precommit` tiene que quedar en verde antes de dar un cambio por terminado.

## Tests

- **Sin red** (RNF-3.8): ESI, SSO y R2Z2 se simulan con `Req.Test` (`test/support/esi_stub.ex`)
  y fixtures en `test/support/fixtures/`.
- **Fixtures del motor** (`Eth.EngineFixture`): un mini SDE (Jita — Perimeter —
  Ahbazon) y `publish_orders/1` para publicar libros de órdenes sintéticos.
- **Casos**: `Eth.DataCase` (base con sandbox) y `EthWeb.ConnCase` (LiveViews). Los
  procesos de fondo no arrancan solos en test: levantá los que necesite cada test con
  `start_supervised!/1` (`TableOwner`, `Coordinator`, `Overrides`, `Metrics`…).
- **LiveView**: `has_element?/3` sobre los `id` de la plantilla, nunca HTML crudo. Para
  sincronizar con un proceso, `:sys.get_state/1`; nunca `Process.sleep/1`.
- **Propiedades** (StreamData) para las invariantes del dominio (ERS §8.3 y §11.2).

## Modo Replay (sin red)

Para desarrollar o depurar sin consultar ESI:

```bash
docker compose exec phoenix mix eth.replay.record                 # graba los snapshots actuales
docker compose exec phoenix mix eth.replay.record --regions 10000002
ETH_DATA_SOURCE=replay docker compose up -d phoenix               # los reproduce
```

En Replay las regiones son las grabadas, no se guardan snapshots y el radar usa las
kills grabadas (`Eth.Threat.ReplayFeed`).

## Depurar

```bash
# Consola IEx conectada al servidor en vivo
docker compose exec phoenix iex --sname console --cookie eth --remsh eth@eth

# Evaluar una expresión en el servidor
docker compose exec phoenix elixir --sname probe --cookie eth --rpc-eval eth@eth \
  'IO.inspect(Eth.Market.RegionPoller.status(10000002))'
```

- **Centro de control** (`/control`): pollers, presupuesto de ESI, radar, motor,
  métricas de la última hora, pipeline y registro de eventos.
- **LiveDashboard** (`/dev/dashboard`, solo en desarrollo): procesos, memoria y ETS.

## Recetas

### Un parámetro calibrable nuevo

1. Agregalo en `config/config.exs` (clave de `Eth.GameRules`) con un comentario.
2. Leelo con `Eth.GameRules.get/1`; nunca como literal.
3. Si el operador debe poder cambiarlo, sumalo al catálogo de `Eth.GameRules.Tunable`
   (ruta, grupo, etiqueta, explicación, tipo y rango): aparece solo en Ajustes → Motor y
   en el respaldo.
4. Documentalo en el Anexo B.7 del ERS y reiniciá el servidor.

### Un término o una sigla en la interfaz

1. Si no se entiende con sentido común, agregalo a `EthWeb.Glossary` (definición en
   lenguaje llano y, si lo hay, el tema de la documentación que lo desarrolla).
2. En la pantalla, `<.term name={:clave} />` en su **primera** aparición por vista. Si va
   dentro de un contenedor que corta el texto (`truncate`), el tooltip se recortaría:
   explicalo en el "?" del panel (`<.help>`) o en el texto de al lado.
3. Los números calculados llevan `<.tip>` con definición y fórmula; los índices y
   conceptos complejos, el "?" en círculo (`<.help topic={...}>`).

### Una sección de la documentación de la app

1. Escribí la plantilla en `lib/eth_web/docs_pages/<página>.html.heex` con
   `<.section_title id="...">`. Los valores del juego se muestran con `rule/1`, nunca
   copiados a mano.
2. Si una pantalla enlaza a esa sección, agregá el tema en `EthWeb.Docs` (`@topics` y
   `summary/1`). Los tests verifican que cada tema apunte a un encabezado que existe.

### Un endpoint de ESI

1. Una función en `Eth.Esi` que llame a `Eth.Esi.Client` (nunca Req directo), con `@doc`
   que diga la ruta y el scope.
2. Verificá la ruta, el método, el scope y el grupo de rate limit contra la OpenAPI de
   ESI (ERS Anexo C).
3. Test con `Req.Test` y las cabeceras reales (`Expires`, `ETag`, `X-Pages`, rate limit).

### Una migración

```bash
docker compose exec phoenix mix ecto.gen.migration nombre_en_ingles
docker compose exec phoenix mix ecto.migrate
```

Tablas y columnas en inglés; documentá el modelo en el ERS §7.

## Git

- Una rama por cambio (`feat/…`, `fix/…`, `docs/…`, `chore/…`); `main` siempre en verde.
- Conventional Commits con el tipo en inglés y la descripción en español, en imperativo y
  de 72 caracteres como mucho; cuerpo opcional y `Refs: RF-x.y`.
- Autor y committer: solo `Hernan Jalabert <benabhi@gmail.com>`, sin trailers de
  coautoría (el hook `commit-msg` y `scripts/check-authorship.sh` lo verifican).
