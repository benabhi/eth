# Cambios

Formato basado en [Keep a Changelog](https://keepachangelog.com/es-ES/1.1.0/) y versiones
según [SemVer](https://semver.org/lang/es/) (RNF-10.7). Cada versión indica si trae
migraciones (corren solas al arrancar) o cambios en `.env`.

## [Sin publicar] — camino a 1.0.0

### Agregado

- **Arranque en un paso:** `iniciar.bat` (Windows) e `iniciar.sh` (macOS/Linux) verifican
  Docker, crean `.env` la primera vez (con `ETH_VAULT_KEY` generada), levantan la app y
  abren el navegador; `detener.bat` / `detener.sh` la apagan.
- **Glosario y ayudas (RF-11.2, RNF-5.14):** glosario único de siglas y términos; en las
  pantallas, subrayado punteado con la definición al pasar el cursor. El menú "Manual" pasa a
  "Documentación" y la búsqueda coincide por comienzo de palabra.
- **Filas expiradas tachadas y congelado con el puntero (RF-6.3)** en las tres familias.
- **Broker fee de estructuras en el motor (RF-9.4):** una estructura con broker propio se
  usa para publicar órdenes en Estación, Listado y Compra por orden.
- **Centro de control:** pipeline en vivo (RF-8.4), métricas de la última hora (RF-8.9) y
  tendencia de los sistemas calientes del radar (RF-8.5).
- **Ajustes → Motor (RF-9.5):** umbrales anti-scam, liquidez, TVS, tiempos por salto y la
  matriz de vulnerabilidad, editables con explicación y rango; se incluyen en el respaldo.

- **Distribución personal (RNF-10.5–10.7):** imagen de producción (`Dockerfile`) y
  `docker-compose.release.yml`: se levanta con un solo comando, las migraciones corren
  solas y los datos viven en volúmenes que sobreviven a las actualizaciones. Guía de
  instalación en el README.
- **Atajos de teclado del tablón (RF-6.9):** `/`, `j`/`k`, `Enter`, `c`, `w`, `f` y `?`.
- **Exportar e importar la configuración (RF-9.7)** en Ajustes → Respaldo, sin secretos.
- **Resaltado de filas nuevas y cambiadas (RF-6.3)** en las tres familias del tablón.
- **Centro de control:** Mercado sin panel lateral (el detalle se despliega bajo la región)
  y Radar rediseñado con indicadores, anillos de amenaza y kills con el ícono de la nave.

### Mejorado

- La fila del tablón muestra siempre los saltos (`24+10`) y los ítems sin imagen (muchos
  SKINs) tienen un ícono de respaldo.
- Filtros más compactos en 1366–1600 px; "Requiere atención" agrupa las regiones y queda en
  una línea; los tooltips que se salían de la pantalla se corren solos.
- Dependencias: `dns_cluster` 0.3 y `phoenix_live_dashboard` 0.9 (A-11).
- **Universo completo por defecto** (69 regiones, ~1,5 M órdenes), también en desarrollo.
- **Rendimiento con el universo completo:** búsqueda con texto precalculado, consultas de
  Estación y Por órdenes repartidas entre los núcleos, intervalo mínimo entre evaluaciones
  del motor y tablas cedidas por la tarea de evaluación. p95 de consulta 19–65 ms
  (antes hasta 283 ms) y memoria de 1,3–1,9 GiB (antes hasta 2,2 GiB).
- Contraste AA en el tema claro (acento y texto tenue).

### Corregido

- Algunos "?" mostraban solo el enlace al manual: ahora todos tienen un texto breve (si no
  traen uno propio, el resumen del tema).
- En los encabezados de las tablas, el "?" de ISK/h se pisaba con Certeza y algunos "?"
  se veían más bajos que el texto.
- Los tooltips dentro de paneles con esquinas en chaflán se cortaban (por ejemplo, Error
  limit en el Centro de control).
- El sello de amenaza del tablón no decía en qué sistema estaba ("Gatecamp" parecía del
  origen): ahora muestra el sistema, por ejemplo "Gatecamp · Hatakani".
- Cambiar de sección recargaba la página y mostraba un instante "Sin conexión".
- La línea base del radar ignoraba los datos que llegaban durante un cálculo hasta el
  ciclo siguiente.
- Abrir una fila podía tardar segundos después de reiniciar el servidor (la pestaña
  quedaba en long polling).

### Funcionalidad hasta aquí (F0–F10)

- **Mercado:** órdenes de todas las regiones y de estructuras Upwell en memoria, respetando
  la caché y los límites de ESI; reinicio en caliente con snapshots; modo Replay sin red.
- **SDE y ruteo:** datos estáticos por build, grafo del universo y rutas Segura, Rápida y
  Evasiva.
- **Motor:** arbitraje directo con walk-the-book e impuestos reales, trading por órdenes
  (Listado y compra por orden) y station trading; TVS y Certeza explicados.
- **Radar:** kills en vivo de zKillboard R2Z2, línea base horaria, detección de camps y
  ganks y riesgo de ruta por nave.
- **Anti-scam y liquidez** con historial de mercado bajo demanda.
- **Personajes (EVE SSO):** billetera, habilidades, standings, nave y bodega con dogma,
  ubicación, órdenes propias; acciones in-game (ruta y mercado).
- **Viaje activo** con etapas, amenazas, revalidación y cierre reconciliado con la
  billetera; registro del cazador con rango, racha e hitos.
- **Alertas** en la app, del navegador y con sonido.
- **Interfaz:** tablón de caza con ficha bajo la fila, Centro de control por pestañas con
  instrumentos, Ajustes, temas oscuro y claro, celular, y manual integrado en `/docs`.
