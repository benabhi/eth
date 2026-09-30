# Cambios

Formato basado en [Keep a Changelog](https://keepachangelog.com/es-ES/1.1.0/) y versiones
según [SemVer](https://semver.org/lang/es/) (RNF-10.7). Cada versión indica si trae
migraciones (corren solas al arrancar) o cambios en `.env`.

## [Sin publicar] — camino a 1.0.0

### Agregado

- **Distribución personal (RNF-10.5–10.7):** imagen de producción (`Dockerfile`) y
  `docker-compose.release.yml`: se levanta con un solo comando, las migraciones corren
  solas y los datos viven en volúmenes que sobreviven a las actualizaciones. Guía de
  instalación en el README.
- **Atajos de teclado del tablón (RF-6.9):** `/`, `j`/`k`, `Enter`, `c`, `w`, `f` y `?`.
- **Exportar e importar la configuración (RF-9.7)** en Ajustes → Respaldo, sin secretos.
- **Resaltado de filas nuevas y cambiadas (RF-6.3)** en las tres familias del tablón.
- **Centro de control:** Mercado sin panel lateral (el detalle se despliega bajo la región)
  y Radar rediseñado con indicadores, anillos de amenaza y kills con el ícono de la nave.

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
