# Auditoría previa a v1.0 (ERS §11.6)

| Campo | Valor |
|---|---|
| Fecha | 2026-09-30 |
| Rama auditada | `feat/f11-endurecimiento` (fusionada en `main` al cerrar F11) |
| Alcance | Los ocho puntos de ERS §11.6 |
| Estado | **Sin hallazgos de severidad alta abiertos.** Queda un punto que solo puede cerrar el piloto con el cliente del juego (§11.4, hallazgo A-05) y dos decisiones para revisar (A-07, A-08). La versión 1.0.0 **no se publica todavía**: la etiqueta y el número de versión quedan para después de la revisión del responsable. |

Severidades: **alta** (bloquea v1.0), **media** (se corrige en el ciclo o se decide explícitamente), **baja** (mejora o deuda menor, con decisión).

## Resumen de hallazgos

| ID | Punto | Hallazgo | Severidad | Estado |
|---|---|---|---|---|
| A-01 | 4. Rendimiento | Con el universo completo, la consulta del tablón medía p95 163 ms (objetivo < 100 ms): la búsqueda normalizaba 7 campos por oportunidad en cada tecla | Media | **Corregido**: texto buscable precalculado al publicar la evaluación (`Eth.Engine.Search`); p95 19 ms |
| A-01b | 4. Rendimiento | Por órdenes y Estación crecen con el historial que llega a demanda (hasta ~10 mil y ~36 mil candidatos): Por órdenes llegó a p95 283 ms, sobre todo por copiar los candidatos con sus libros al proceso de la vista | Media | **Corregido**: consulta repartida entre los núcleos (cada tarea lee su parte de ETS y devuelve solo sus primeras filas); p95 65 ms y 24 ms |
| A-02 | 4. Rendimiento | Memoria RSS con picos de 2,18 GiB (objetivo ≤ 2 GB): vivían hasta 4 versiones de las tablas de oportunidades (gracia de 30 s y evaluaciones cada ~7 s), la generación anterior de órdenes 60 s, y el coordinador del motor recibía en su heap de larga vida las listas completas de candidatos | Media | **Corregido**: gracia de órdenes 20 s y de oportunidades 5 s, intervalo mínimo entre evaluaciones de 10 s y tablas llenadas por la tarea de evaluación y cedidas al coordinador (`:ets.give_away/3`) y familias evaluadas por etapas con recolección en el medio (ver §4) |
| A-03 | 4. Rendimiento | Precalcular el texto buscable sin memoizar subió la evaluación a 6–9 s (36 mil candidatos de estación con pocos miles de nombres) | Media | **Corregido** en el mismo ciclo: cada cadena distinta se normaliza una vez por evaluación |
| A-04 | 4. Rendimiento | RNF-1.2 (propagación < 3 s en regiones no-hub, < 12 s en The Forge) no se cumple con el universo completo: la evaluación sola tarda 4–6 s y ahora hay un intervalo mínimo de 10 s | Media | **Decisión propuesta** (a revisar): ajustar RNF-1.2 a "< 20 s con el universo completo". Las órdenes de cada región cambian cada 300 s en ESI, así que 16 s de demora no cambian qué trades se ven |
| A-05 | 3. Punta a punta | El checklist manual §11.4 (login con los 13 scopes, fijar ruta y ruta evasiva, abrir mercado, pegar un Multibuy, cambio de nave) necesita el cliente del juego y un personaje real | Media | **Pendiente del piloto**: el login con la app real y los 13 scopes ya se probaron en F4 y F9; el resto se verifica antes de etiquetar v1.0 |
| A-06 | 5. Seguridad | Sobelow marca "HTTPS no habilitado" | Baja | **Decisión** (D-22): la app corre por HTTP solo en 127.0.0.1; excepción puntual en `.sobelow-skips`, justificada en `.sobelow-conf` |
| A-07 | 6. Calidad | Cobertura de `Eth.Threat` 72,6 % (objetivo 85 %): `ReplayFeed`, el adaptador del feed y el supervisor sin tests | Media | **Corregido**: tests de `ReplayFeed`, `KillFeed` y del supervisor (sin tocar la red); 89,8 % |
| A-08 | 6. Calidad | Pendientes menores del ERS aún abiertos: métricas de 1 h (RF-8.9), pipeline en vivo (RF-8.4), tendencia de sistemas calientes (RF-8.5), presets de filtros (RF-6.4), resto de parámetros de RF-9.5, calibración de la Certeza con los viajes (RF-7.6), broker fee por estructura en el motor (RF-9.4) y filas expiradas tachadas (RF-6.3) | Baja | **Resuelto en F12** (2026-09-30): implementados todos salvo la calibración de la Certeza (RF-7.6, necesita viajes reales) y los presets de filtros (RF-6.4, descartados por el operador: los filtros viven en la URL) |
| A-09 | 7. Documentación | ERS B.7 describía una "reserva del 10 %" del presupuesto de mercado que no existe: lo implementado es la política por nivel de §8.11 | Baja | **Corregido** en el ERS |
| A-10 | 8. Accesibilidad | En el tema claro, el ámbar de acento (4,2:1) y el texto tenue (3,5:1) no llegaban a 4,5:1 | Media | **Corregido**: `#a26000` y `#647183` (4,6:1 sobre `base-200`, 5:1 sobre blanco) |
| A-11 | 5. Seguridad | Dos dependencias con versión mayor nueva que el requisito de `mix.exs` no permite: `dns_cluster` 0.3 (sin uso: no hay clúster) y `phoenix_live_dashboard` 0.9 (solo desarrollo) | Baja | **Resuelto en F12**: `dns_cluster` 0.3 y `phoenix_live_dashboard` 0.9 |
| A-12 | 4. Rendimiento | La imagen de producción mostraba "Failed open sctp dynamic library" en cada comando | Baja | **Corregido**: `libsctp1` en la imagen |

## 1. Al día con EVE

- **ESI.** Los 21 endpoints que usa la aplicación (`Eth.Esi`) se verificaron contra la OpenAPI vigente de ESI (`/meta/openapi.json`), tanto la versión por defecto como la de la fecha de compatibilidad que envía la aplicación (`2026-09-01`, que ESI resuelve a la última disponible, `2026-08-18`): **todas las rutas y métodos existen**, los scopes coinciden con los 13 que pide la aplicación y los grupos de rate limit que declara el código (`char-location`, `char-wallet`, `char-detail`, `char-social`, `char-asset`, `market-order`, `status`, `ui`) son los de la especificación.
- **Presupuesto real.** El grupo `market-order` informa 12.000 tokens cada 15 minutos. La primera descarga del universo completo (~5.000 páginas) usa la mayor parte; el limitador reparte el ciclo siguiente según §8.11 y, con ETag/304, en régimen quedan frescas 64–69 de las 69 regiones.
- **EVE SSO.** Login con la aplicación real, los 13 scopes, JWKS y refresh token verificados en F4 y F9 (scope 13 de órdenes). Sin cambios desde entonces.
- **SDE.** Build 3552227: descarga y proceso en 20 s, 5.227 sistemas ruteables, 5.210 estaciones y 19.566 tipos de mercado; desde caché, 0 s.
- **Servidor de imágenes** (`images.evetech.net`): retratos, íconos de tipos y renders de naves en uso en toda la interfaz.
- **zKillboard R2Z2.** Feed en vivo con atraso de 9–35 s, sin 403 ni 429 durante las pruebas; User-Agent con contacto.

## 2. Reglas del juego

Los valores de `Eth.GameRules` se verificaron contra las fuentes del Anexo C en su fase (impuestos y broker en F3/F9, reglas de órdenes P-12 en F9, dogma de la bodega en F4, grupos de naves del radar contra el SDE 3552227 en F6) y se muestran en vivo en el manual (`/docs/impuestos`). No hubo cambios de CCP que los afecten desde entonces. Los parámetros nuevos de F10–F11 (rangos, peligro, hitos, gracias e intervalo del motor) están documentados en el Anexo B.7 y son calibrables.

## 3. Funcionalidad de punta a punta

- **Tres familias con datos reales del universo completo:** 3.200 oportunidades directas, 36.300 candidatos de estación y 2.900 por órdenes.
- **Viaje activo y registro del cazador:** flujo completo cubierto por tests (inicio desde el tablón, etapas, cierre, reconciliación simulada, hitos y toast).
- **Alertas:** toasts en la app, del navegador y de hitos cubiertos por tests.
- **Imagen de producción:** construida y levantada de punta a punta (migraciones automáticas, SDE, universo, reinicio con snapshots).
- **Pendiente del piloto:** checklist §11.4 con el cliente del juego (A-05).

## 4. Rendimiento y recursos (RNF-1)

Medido sobre la **imagen de producción** con el universo completo: 69 regiones, ~1,55 M órdenes, más ~28 estructuras. Máquina de desarrollo con Docker Desktop en Windows 11.

| Requisito | Objetivo | Medido | Estado |
|---|---|---|---|
| RNF-1.1 Consulta del tablón (p95) | < 100 ms | Directo **19 ms** (antes 163), Estación **24 ms** (antes 82), Por órdenes **65 ms** (antes 283), con 3.150 / 36.300 / 9.900 candidatos | ✓ |
| RNF-1.2 Propagación snapshot → UI | < 3 s / < 12 s | ≤ ~16 s (intervalo mínimo 10 s + evaluación) | Ver A-04 |
| RNF-1.3 Evaluación del universo | < 10 s | 2,7–5 s en régimen; 7,4 s en la primera tras restaurar snapshots | ✓ |
| RNF-1.4 Arranque en frío (SDE en caché) | hubs < 60 s · universo < 6 min | primera evaluación a los **8 s** · universo completo a los **53 s** | ✓ |
| RNF-1.4 Arranque en frío (sin SDE) | — | universo completo a los **74 s** | ✓ |
| RNF-1.4 Arranque en caliente | < 20 s | **13 s** (69 snapshots restaurados) | ✓ |
| RNF-1.5 Memoria | ≤ 2 GB RSS | RSS **1,27–1,88 GiB** en 11,5 min y 50 evaluaciones (antes hasta 2,18 GiB); memoria de la VM con pico de 1,23 GB (antes 1,9 GB); ETS 570–790 MB | ✓ (1,88 GiB ≈ 2,0 GB: margen chico, ver nota) |
| RNF-1.6 Filas por render | ≤ 200 | 200 (tests de LiveView) | ✓ |

**Nota sobre la memoria.** El pico de RSS lo marca la tarea de evaluación mientras calcula (su heap es transitorio), no lo retenido. Tres cambios lo bajaron:
- vida corta de las versiones anteriores;
- tablas llenadas por la tarea y cedidas al coordinador;
- cada familia evaluada, volcada y liberada antes de la siguiente, con una recolección en el medio.

También se probó ajustar el asignador de ETS (`+MEas aobf +MEacul de +MElmbcs`): no cambió ni el pico ni la fragmentación medida (986 → 925 MB de portadores para ~550 MB en uso), así que **se descartó**. Si en otra máquina hiciera falta más margen, `ETH_REGIONS` limita las regiones (README).

**Dónde estaba la memoria (antes de A-02):**

| Tabla | Memoria |
|---|---|
| Órdenes (97 tablas) | 290 MB |
| Candidatos de estación (4 versiones vivas) | 284 MB |
| Resúmenes del motor | 109 MB |
| Oportunidades por órdenes (4 versiones) | 48 MB |

## 5. Seguridad y privacidad

- `mix sobelow`: sin hallazgos, salvo la excepción justificada A-06 y dos `# sobelow_skip` puntuales sobre archivos temporales o de datos, nunca rutas externas.
- `mix deps.audit` y `mix hex.audit`: **sin vulnerabilidades ni paquetes retirados**. Dependencias al día salvo A-11.
- **CSP** estricta, sin `unsafe-inline`: el único script inline, el del tema, va autorizado por hash, y los scripts y estilos externos están bloqueados.
- **Tokens** cifrados con AES-256 (Cloak, `ETH_VAULT_KEY`); nunca se loguean. La exportación de configuración (RF-9.7) no incluye personajes ni tokens (test).
- **Imagen de producción:** `.env` y los datos locales excluidos por `.dockerignore`, proceso como `nobody`, puerto publicado solo en 127.0.0.1 y base sin puertos publicados.
- **Acciones in-game** solo por clic o tecla explícita del piloto.

## 6. Calidad

- **Tests:** 322, 7 de ellos de propiedades, sin llamadas a servicios reales. Credo `--strict`, Dialyzer y formato en verde.
- **Cobertura** (`mix test --cover`, objetivo §11.3):

| Contexto | Cobertura | Objetivo |
|---|---|---|
| Global | 84,0 % | 70 % |
| `Eth.Engine` | 89,7 % | 85 % |
| `Eth.Routing` | 94,3 % | 85 % |
| `Eth.Esi` | 89,8 % | 85 % |
| `Eth.Threat` | 89,8 % | 85 % |

  `Eth.Threat` estaba en 72,6 % antes de A-07.
- **Test intermitente** de la línea base del radar: era un error real (datos que llegaban durante un cálculo) y está corregido.
- **Pendientes menores:** ver A-08.

## 7. Documentación

- **ERS:** notas de implementación de F10 y F11 y Anexo B.7 al día (A-09); decisiones D-21 y D-22.
- **`CLAUDE.md`:** estado de fases, mapa del código y comandos, incluido que el desarrollo escanea ahora todo el universo por defecto.
- **README:** guía de instalación paso a paso, actualización, respaldo y problemas frecuentes.
- **`CHANGELOG.md`**, **`.env.example`** ordenado y **manual integrado** (`/docs`) con resúmenes en todos los "?" (test).

## 8. Accesibilidad y diseño

- **Revisión automática** de las 19 pantallas y del tablón con datos, en los tres tamaños:
  - sin botones ni enlaces sin nombre accesible, sin campos sin etiqueta y sin IDs duplicados;
  - un `h1` por página y `lang="es"`;
  - filas del tablón enfocables con contorno visible y atajos de teclado (RF-6.9).
- **Contraste AA** en el tema oscuro para todos los colores de texto; en el claro, corregido (A-10).
- **Celular (375 px)** sin desborde horizontal en ninguna pantalla; filtros plegables.
- **Movimiento:** las animaciones respetan `prefers-reduced-motion`.
