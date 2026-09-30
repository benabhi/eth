# EVE Trade Hunter

Herramienta **personal y autoalojada** para cazar trades en EVE Online. Escanea el mercado
de todas las regiones (ESI), cruza cada oportunidad con tu contexto real (billetera,
habilidades, nave, ubicación e impuestos, vía EVE SSO) y la puntúa según el riesgo de la
ruta (radar de zKillboard en vivo) y un escudo anti-scam. Corre en tu computadora: nada
sale de tu máquina salvo las consultas a los servicios oficiales de EVE y a zKillboard.

- **Tablón de caza:** trades directos, por órdenes y station trading, con rango, Certeza,
  peligro de ruta y la ficha de cada contrato con su cálculo explicado.
- **Viaje activo:** etapas, amenazas en la ruta, revalidación y cierre con el resultado
  real de tu billetera; registro del cazador con hitos.
- **Centro de control:** qué descarga la aplicación, cuánto presupuesto de EVE le queda y
  cómo andan el radar y el motor.
- **Manual integrado** en `/docs`, con las fórmulas y los valores vigentes.

> Documentación: la de uso está dentro de la aplicación (menú **Documentación**) y la
> técnica, en [docs/](docs/README.md). Ver [Documentación](#documentación).

---

## Instalación

### 1. Requisitos

- **Docker Desktop** (Windows o macOS) o Docker Engine con Compose (Linux).
- Unos **4 GB de RAM libres** para escanear todo el universo (menos si limitás las
  regiones, ver [Ajustes útiles](#ajustes-útiles)) y ~2 GB de disco.
- Una cuenta de EVE Online.

No hace falta instalar Elixir, PostgreSQL ni nada más: todo corre en contenedores.

### 2. Descargar

Cloná el repositorio (o bajá el `.zip` del release y descomprimilo) y abrí una terminal en
su carpeta:

```bash
git clone https://github.com/benabhi/eth.git
cd eth
```

### 3. Registrar tu aplicación de EVE

Cada instalación usa **su propia** aplicación de desarrollador de EVE: así tu presupuesto
de consultas y tus datos son solo tuyos.

1. Entrá a <https://developers.eveonline.com/applications> con tu cuenta de EVE y creá
   una aplicación nueva con **Authentication & API Access**.
2. **Callback URL** (exacta): `http://localhost:4000/auth/eve/callback`
3. Marcá estos permisos (*scopes*):

   ```text
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
   ```

   Si falta alguno, la función que lo usa te avisa y el resto sigue andando.
4. Guardá y copiá el **Client ID** y el **Secret Key**.

### 4. Configurar `.env`

Copiá el ejemplo:

```bash
cp .env.example .env
```

(en PowerShell: `Copy-Item .env.example .env`) y completá:

| Variable | Qué poner |
|---|---|
| `EVE_CLIENT_ID` | El Client ID del paso 3 |
| `EVE_CLIENT_SECRET` | El Secret Key del paso 3 |
| `ESI_CONTACT` | Tu email: EVE lo pide en el User-Agent para poder contactarte |
| `ETH_VAULT_KEY` | Clave que cifra tus tokens de EVE (ver abajo) |

Generá `ETH_VAULT_KEY` con este comando (funciona igual en Windows, macOS y Linux) y pegá
el resultado:

```bash
docker run --rm alpine sh -c "head -c 32 /dev/urandom | base64"
```

**Guardá una copia de esa clave.** Sin ella, los tokens guardados no se pueden leer y hay
que volver a iniciar sesión con cada personaje (no se pierde nada más).

### 5. Levantar

```bash
docker compose -f docker-compose.release.yml up -d --build
```

La primera vez construye la imagen (unos minutos) y, ya en marcha, descarga los datos
estáticos de EVE (~100 MB) y el mercado. Abrí <http://localhost:4000>: en un par de
minutos el tablón empieza a llenarse. **Ajustes → Primer arranque** muestra qué falta.

### 6. Iniciar sesión

Tocá **Iniciar sesión con EVE**, elegí tu personaje y aceptá los permisos. Aparece la
barra del piloto con tu billetera, nave, ubicación y sales tax, y el tablón se ordena para
vos. Podés agregar más personajes desde el menú del retrato.

---

## Documentación

**Para el piloto**, dentro de la aplicación (menú *Documentación*, con la aplicación
corriendo). Las fórmulas muestran los valores vigentes de tu instalación:

| Página | Enlace |
|---|---|
| Primeros pasos: instalar y registrar tu app de EVE | <http://localhost:4000/docs/primeros-pasos> |
| El tablón de caza y las familias Directo, Por órdenes y Estación | <http://localhost:4000/docs/tablon> · <http://localhost:4000/docs/familias> |
| Cómo se calculan los números: impuestos, walk-the-book, TVS y Certeza, anti-scam | <http://localhost:4000/docs/impuestos> · <http://localhost:4000/docs/tvs-certeza> |
| En ruta: radar, bodega y viaje activo | <http://localhost:4000/docs/radar> · <http://localhost:4000/docs/viaje> |
| Centro de control, Ajustes y límites de ESI | <http://localhost:4000/docs/centro-de-control> · <http://localhost:4000/docs/ajustes> |
| Glosario de siglas y términos | <http://localhost:4000/docs/glosario> |

**Para quien desarrolla**, en [`docs/`](docs/README.md):

| Documento | Qué contiene |
|---|---|
| [Arquitectura](docs/arquitectura.md) | Flujo de datos, árbol de supervisión, ETS, PubSub, base de datos y capa web. |
| [Motor](docs/motor.md) | Evaluación universal, consulta personalizada y dónde vive cada fórmula. |
| [Desarrollo](docs/desarrollo.md) | Entorno, tests, modo Replay, depuración y recetas. |
| [ERS](docs/ERS.md) | Especificación de requisitos: la fuente de verdad funcional. |
| [Auditoría v1.0](docs/audit-v1.0.md) | Rendimiento, seguridad, calidad y hallazgos. |
| [CHANGELOG](CHANGELOG.md) | Cambios por versión. |

## Uso diario

```bash
docker compose -f docker-compose.release.yml up -d     # arrancar
docker compose -f docker-compose.release.yml stop      # detener (guarda el mercado en disco)
docker compose -f docker-compose.release.yml logs -f app   # ver qué está haciendo
```

Al detenerla se guardan los snapshots del mercado: el próximo arranque tarda segundos y no
vuelve a descargar lo que sigue vigente.

Atajos del tablón: `/` buscar · `j`/`k` recorrer · `Enter` abrir la ficha · `c` copiar ·
`w` fijar ruta · `f` congelar · `?` ayuda.

## Actualizar a una versión nueva

```bash
git pull
docker compose -f docker-compose.release.yml up -d --build
```

Las migraciones de la base corren solas al arrancar y los volúmenes (base, SDE, snapshots)
se conservan: no se pierde ningún dato. Los cambios de cada versión están en
[CHANGELOG.md](CHANGELOG.md).

## Respaldo

- **Ajustes → Respaldo** exporta tu configuración (reglas, parámetros del motor, radar,
  alertas, naves y estructuras) a un JSON sin secretos, y la importa en otra instalación.
- Tus datos viven en dos volúmenes de Docker: `eth-release_pgdata` (base) y
  `eth-release_data` (SDE, snapshots). Para empezar de cero (se pierde el historial de
  viajes): `docker compose -f docker-compose.release.yml down -v`.

## Ajustes útiles

Todos van en `.env` y se aplican al reiniciar (`up -d`):

| Variable | Para qué |
|---|---|
| `ETH_REGIONS` | Limitar el escaneo a algunas regiones (IDs separados por comas; por ejemplo `10000002,10000043` para The Forge y Domain). Vacío: todo el universo. Usa menos memoria y presupuesto de ESI. |
| `ETH_KILLFEED` | `off` apaga el radar en vivo (queda la línea base). |
| `ETH_ALLOWED_CHARACTER_IDS` | Solo estos personajes pueden iniciar sesión (IDs separados por comas). |

## Problemas frecuentes

- **"Invalid callback" al iniciar sesión:** la Callback URL de tu aplicación de EVE tiene
  que ser exactamente `http://localhost:4000/auth/eve/callback`.
- **El puerto 4000 está ocupado:** cambiá `127.0.0.1:4000:4000` por otro puerto del host
  en `docker-compose.release.yml` (el callback también cambia).
- **Perdí `ETH_VAULT_KEY`:** poné una nueva y volvé a iniciar sesión con cada personaje.
- **El tablón está vacío:** mirá el **Centro de control**: los mercados tardan unos minutos
  en descargarse la primera vez y el historial se pide de a poco.

---

## Desarrollo

El entorno de desarrollo (live reload, tests, consola) usa `docker-compose.yml`:

```bash
docker compose up --build
docker compose exec phoenix mix precommit
```

Guía de desarrollo: [docs/desarrollo.md](docs/desarrollo.md). Arquitectura y motor:
[docs/arquitectura.md](docs/arquitectura.md) y [docs/motor.md](docs/motor.md). Reglas del
proyecto y convenciones: [CLAUDE.md](CLAUDE.md). Requisitos: [docs/ERS.md](docs/ERS.md).

## Licencia y avisos

EVE Online y todos los nombres, logos e imágenes relacionados son propiedad de CCP hf.
Esta herramienta no está afiliada ni respaldada por CCP. Los datos de kills provienen de
[zKillboard](https://zkillboard.com). Las fuentes tipográficas incluidas tienen licencia
SIL OFL (ver `priv/static/fonts/`).
