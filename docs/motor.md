# Motor

El motor tiene dos mitades con responsabilidades distintas:

- **Evaluación universal** (`Eth.Engine.Coordinator` y los evaluadores): corre de fondo
  cada vez que el mercado cambia, **sin contexto personal** (modo invitado, cotas
  optimistas) y deja candidatos en ETS.
- **Consulta personalizada** (`Eth.Engine.query/1`, `station_query/1`, `order_query/1`):
  corre en cada render del tablón con el contexto del piloto (Accounting, capital,
  bodega, ubicación, nave, standings, órdenes propias) y el radar.

Así el trabajo pesado se hace una vez para todos los pilotos y cada consulta solo ajusta
números sobre candidatos ya filtrados (RNF-1.1: p95 < 100 ms). Las fórmulas están en el
ERS §8; este documento dice dónde vive cada una.

## Evaluación

`Eth.Engine.Coordinator` escucha `market:snapshots` y el estado del SDE:

1. **Agrupa** los disparadores con un debounce de 2 s y respeta un intervalo mínimo entre
   evaluaciones (`:engine_min_interval_ms`). Corre una sola evaluación a la vez; lo que
   llega mientras tanto se junta en la siguiente.
2. **Resúmenes** (`Eth.Engine.Summary`): por `{fuente, tipo}`, mejores ventas por
   ubicación y todas las compras. Solo se recalculan las fuentes con generación nueva.
3. **Familias**, por etapas, liberando memoria entre una y otra:

| Familia | Evaluador | Qué produce |
|---|---|---|
| Directo | `Evaluator` | Arbitraje instantáneo entre ubicaciones: screening con los resúmenes y walk-the-book (`Book`) con las compras que cubren cada estación por rango (`Range`). |
| Estación | `StationEvaluator` | Station trading en los lugares de publicación (`PublishLocations`: hubs NPC y estructuras con broker propio), con el libro de la estación. |
| Por órdenes | `OrderEvaluator` | Listado y compra por orden entre una estación NPC y un lugar de publicación. |

4. **Publicación**: cada familia se escribe en una tabla ETS nueva, la tarea de evaluación
   se la cede al coordinador (`:ets.give_away/3`), el catálogo cambia atómicamente
   (versión + 1) y la tabla anterior se borra tras `:engine_grace_ms`. Se anuncia
   `{:opportunities_updated, meta}` en `engine:opportunities`.
5. **Historial a demanda**: los pares `(región, tipo)` de las oportunidades se declaran a
   `Eth.Market.History` con prioridad; el historial que llega mejora la consulta siguiente
   sin volver a evaluar.

El texto buscable de cada candidato se precalcula al publicar (`Eth.Engine.Search`).

## Consulta

| Familia | Módulo | Cálculo |
|---|---|---|
| Directo | `Eth.Engine.Query` | Impuestos del piloto (`Fees`), capital y bodega (vuelve a recorrer el libro solo si hace falta), triángulo piloto → origen → destino (`Routing`), tiempo e ISK/h (`Score`), liquidez (`Liquidity`), anti-scam (`Shield`), riesgo de ruta (`RouteRisk`), Certeza y TVS (`Score`). |
| Estación | `StationQuery` + `StationTrading` | Precios legales (tick), broker ×2 y sales tax, volumen diario, competencia y plan por capital. |
| Por órdenes | `OrderQuery` + `OrderRules` | Precio que supera a la mejor orden, espera estimada por volumen y competencia, broker del lugar. |

Estación y Por órdenes tienen decenas de miles de candidatos: `Eth.Engine` reparte la
consulta entre los núcleos (cada tarea lee su parte de ETS y devuelve solo sus primeras
filas) y descarta primero, sin copiar los candidatos, los pares sin historial suficiente.

El resultado se ordena en el servidor y se corta en 200 filas (RNF-1.6).

## Módulos de apoyo

| Módulo | Qué hace |
|---|---|
| `Book` | Walk-the-book: cuánto se compra y se vende orden por orden. |
| `Fees` | Sales tax y broker fee (NPC) según habilidades y standings. |
| `OrderRules` | Tick de precio legal, costo de modificar (relist), límite de órdenes. |
| `Shield` | Escudo anti-scam AS-1…AS-7 y la Certeza de cada estado. |
| `Liquidity` | Índice de liquidez y sello ilíquido. |
| `RouteRisk` | Riesgo de la ruta con el mapa de calor, la línea base y la matriz de vulnerabilidad. |
| `Score` | Tiempo de viaje, ISK/h, utilidad, Certeza y TVS. |
| `Grade` | Rango del contrato (S–D), peligro y rango del cazador. |
| `Locations` | Nombre, sistema, seguridad y si es estructura. |
| `PublishLocations` | Hubs NPC y estructuras con broker propio donde se publican órdenes. |
| `OwnOrders` | Estado de las órdenes propias frente al libro. |
| `SaleQuote` | Recotiza la venta de una carga ya comprada (viaje activo). |
| `ScamReport` | Foto de una oportunidad reportada como falso positivo. |

## Parámetros

Ningún número del juego ni umbral es un literal en el código (RNF-15): todo sale de
`Eth.GameRules`, que lee `config :eth, Eth.GameRules` y le superpone los **overrides**
publicados en ETS:

- reglas del juego (impuestos, broker) desde Ajustes → Reglas (`GameRules.overridable/0`);
- radar (α de la ruta Evasiva, sistemas a evitar) desde Ajustes → Radar;
- parámetros del motor (anti-scam, liquidez, TVS, tiempos, matriz de vulnerabilidad)
  desde Ajustes → Motor (`Eth.GameRules.Tunable`).

`Eth.GameRules.Overrides` publica todo al arrancar y al guardar; guardar pide una
evaluación nueva. En tests que cambian la configuración con `Application.put_env/3`, hay
que llamar a `Eth.GameRules.reload/0`.
