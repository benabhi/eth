defmodule EthWeb.Glossary do
  @moduledoc """
  Glosario de la aplicación (RF-11.2, RNF-5.14): una sola fuente para la página
  Glosario de la documentación, la búsqueda y el componente `EthWeb.UI.term/1`, que
  explica una sigla o un término del juego en el lugar donde aparece.

  Cada término tiene una clave (`:sde`), el nombre que se muestra, sinónimos para la
  búsqueda, una definición breve en lenguaje llano y, si lo hay, el tema de la
  documentación que lo desarrolla (`EthWeb.Docs`). Un test verifica que todos los temas
  existan y que cada definición sea autosuficiente.

  Implementa: RF-11.2, RNF-5.14.
  """

  use Gettext, backend: EthWeb.Gettext

  alias Eth.GameRules

  @type entry :: %{
          key: atom(),
          term: String.t(),
          aliases: [String.t()],
          definition: String.t(),
          topic: atom() | nil
        }

  @doc "Términos del glosario, en orden alfabético."
  @spec entries() :: [entry()]
  def entries do
    [
      e(
        :accounting,
        "Accounting",
        [],
        gettext("Habilidad del juego que baja el sales tax: cada nivel lo reduce un %{pct} %%.",
          pct: round(GameRules.get(:accounting_reduction_per_level) * 100)
        ),
        :sales_tax
      ),
      e(
        :backoff,
        "Backoff",
        ["reintento"],
        gettext(
          "Espera creciente antes de reintentar una consulta que falló, para no insistir contra un servicio caído."
        ),
        :esi_limits
      ),
      e(
        :broker,
        "Broker fee",
        ["broker", "comisión"],
        gettext(
          "Comisión que cobra el mercado al publicar una orden. Baja con la habilidad Broker Relations y los standings."
        ),
        :broker
      ),
      e(
        :camp,
        "Camp",
        ["gatecamp", "gate camp", "bubble", "bubble camp", "smartbomb"],
        gettext(
          "Jugadores apostados en un sistema, casi siempre en un portal, para destruir a quien pasa. Bubble camp: usan burbujas que impiden saltar; smartbomb: explosiones en área contra naves pequeñas."
        ),
        :radar
      ),
      e(
        :ccp,
        "CCP",
        [],
        gettext(
          "CCP Games, la empresa que desarrolla EVE Online y opera sus servicios (ESI, SSO)."
        ),
        nil
      ),
      e(
        :certainty,
        "Certeza",
        [],
        gettext(
          "Probabilidad (0–100 %) de que el contrato salga como se calculó cuando llegues: frescura de los datos, historial, acceso y peligro de la ruta."
        ),
        :certainty
      ),
      e(
        :contract,
        "Contrato",
        ["oportunidad"],
        gettext(
          "Una oportunidad de trade del tablón: qué comprar, dónde venderlo y cuánto se gana."
        ),
        :board
      ),
      e(
        :downtime,
        "Downtime",
        ["mantenimiento"],
        gettext(
          "Mantenimiento diario del servidor de EVE (de %{from} a %{to} UTC). Mientras dura, la app no consulta el mercado.",
          downtime_window()
        ),
        :esi_limits
      ),
      e(
        :error_limit,
        "Error limit",
        ["límite de errores"],
        gettext(
          "Cantidad de respuestas con error que ESI tolera por minuto. Si se agota, EVE bloquea temporalmente a tu IP; la app frena antes."
        ),
        :budgets
      ),
      e(
        :escrow,
        "Escrow",
        [],
        gettext("El ISK que queda inmovilizado mientras una orden de compra está abierta."),
        :own_orders
      ),
      e(
        :esi,
        "ESI",
        [],
        gettext(
          "EVE Swagger Interface: la interfaz oficial de datos de EVE Online. De ahí salen el mercado, tu billetera, tus habilidades y tu ubicación."
        ),
        :esi_limits
      ),
      e(
        :eta,
        "ETA",
        [],
        gettext("Tiempo estimado de llegada: cuánto falta para completar el viaje."),
        :run
      ),
      e(
        :ets,
        "ETS",
        [],
        gettext("Tablas en memoria donde la app guarda el mercado para consultarlo al instante."),
        :control
      ),
      e(
        :gank,
        "Gank",
        [],
        gettext(
          "Ataque en highsec para destruir una nave de carga y saquearla, aceptando la pérdida de las naves atacantes."
        ),
        :radar
      ),
      e(
        :generation,
        "Generación",
        ["gen."],
        gettext(
          "Número de versión de los datos de una región: sube cada vez que llegan órdenes nuevas."
        ),
        :pollers
      ),
      e(
        :hub,
        "Hub",
        [],
        gettext(
          "Estación con mucho mercado: Jita IV-4, Amarr VIII, Dodixie IX-20, Rens VI-8 y Hek VIII-12."
        ),
        nil
      ),
      e(:isk, "ISK", [], gettext("La moneda de EVE Online."), nil),
      e(
        :isk_per_hour,
        "ISK/h",
        [],
        gettext(
          "Beneficio por hora de viaje, contando los saltos desde tu ubicación hasta el destino."
        ),
        :isk_per_hour
      ),
      e(
        :liquidity,
        "Liquidez",
        ["ilíquido"],
        gettext(
          "Qué tanto se opera un objeto: si es ilíquido, vender la cantidad del contrato puede llevar días."
        ),
        :liquidity
      ),
      e(
        :baseline,
        "Línea base",
        ["lo habitual"],
        gettext(
          "Cuántas kills y saltos hay normalmente en cada sistema a cada hora. El radar compara la actividad en vivo contra ese normal."
        ),
        :radar
      ),
      e(
        :pvp,
        "PvP",
        ["jugador contra jugador"],
        gettext(
          "Combate entre jugadores (player versus player). El radar solo cuenta kills PvP, no las de la IA del juego."
        ),
        :radar
      ),
      e(
        :scope,
        "Scope",
        ["scopes", "permiso", "permisos"],
        gettext(
          "Cada permiso que un personaje le da a la app al iniciar sesión con EVE: leer la billetera, la ubicación, fijar la ruta, etc."
        ),
        :scopes
      ),
      e(
        :multibuy,
        "Multibuy",
        [],
        gettext(
          "Ventana del mercado del juego para comprar varios objetos a la vez pegando una lista."
        ),
        :board
      ),
      e(
        :npc,
        "Estación NPC",
        ["NPC"],
        gettext("Estación del juego (no de jugadores): siempre accesible, con comisiones fijas."),
        :broker
      ),
      e(
        :poller,
        "Poller",
        ["pollers"],
        gettext(
          "Proceso que descarga periódicamente el mercado de una región. N1 son los hubs (más seguido), N2 regiones activas y N3 el resto."
        ),
        :pollers
      ),
      e(
        :rate_limit,
        "Rate limit",
        ["presupuesto", "límite de consultas"],
        gettext(
          "Cantidad de consultas por minuto que ESI permite. La app reparte ese presupuesto entre mercado, historial y personajes."
        ),
        :budgets
      ),
      e(
        :r2z2,
        "R2Z2",
        ["zKillboard", "kill feed", "killmail"],
        gettext(
          "El feed en vivo de zKillboard: cada nave destruida en EVE, segundos después. Alimenta el radar."
        ),
        :radar_feed
      ),
      e(
        :relist,
        "Relist",
        ["modificar orden"],
        gettext(
          "Cambiar el precio de una orden publicada: vuelve a cobrar parte del broker fee."
        ),
        :relist
      ),
      e(
        :roi,
        "ROI",
        [],
        gettext("Retorno sobre la inversión: beneficio dividido lo invertido."),
        :profit
      ),
      e(
        :sales_tax,
        "Sales tax",
        ["impuesto"],
        gettext("Impuesto que cobra el mercado al vender. Baja con la habilidad Accounting."),
        :sales_tax
      ),
      e(
        :scam,
        "SCAM",
        ["escudo", "anti-scam", "sospechoso"],
        gettext(
          "Contrato que parece una trampa (precios inflados, órdenes señuelo). El escudo lo oculta y bloquea sus acciones."
        ),
        :shield
      ),
      e(
        :sde,
        "SDE",
        ["datos estáticos"],
        gettext(
          "Static Data Export: los datos fijos de EVE que publica CCP (mapa, estaciones, objetos, naves y atributos). La app lo descarga una vez por versión del juego."
        ),
        nil
      ),
      e(
        :security,
        "Seguridad del sistema",
        ["highsec", "lowsec", "nullsec", "sec"],
        gettext(
          "Nivel de 1.0 a -1.0 de cada sistema. Highsec (0.5 a 1.0): la policía castiga los ataques. Lowsec (0.1 a 0.4) y nullsec (0.0 o menos): sin protección."
        ),
        :danger
      ),
      e(
        :snapshot,
        "Snapshot",
        [],
        gettext(
          "Copia completa del mercado de una región en un momento dado. Se guarda al apagar para no volver a descargarla."
        ),
        :pollers
      ),
      e(
        :sso,
        "SSO",
        ["login", "EVE SSO"],
        gettext(
          "Single Sign-On: el inicio de sesión oficial de EVE. Autoriza a la app a leer datos de tus personajes sin darle tu contraseña."
        ),
        :scopes
      ),
      e(
        :standings,
        "Standings",
        [],
        gettext(
          "Tu reputación con cada facción y corporación del juego. Una reputación alta con el dueño de la estación baja el broker fee."
        ),
        :broker
      ),
      e(
        :structure,
        "Estructura Upwell",
        ["Upwell", "estructura", "ciudadela"],
        gettext(
          "Estación construida por jugadores. Su dueño decide quién entra y cuánto cobra; algunas son privadas."
        ),
        :board
      ),
      e(
        :tick,
        "Tick",
        [],
        gettext(
          "El paso mínimo de precio de una orden: como mucho %{digits} cifras significativas (con 4: 1.234.000 sí, 1.234.567 no).",
          digits: GameRules.get(:order_price_significant_digits)
        ),
        :relist
      ),
      e(
        :broker_relations,
        "Broker Relations",
        ["Advanced Broker Relations"],
        gettext(
          "Habilidad del juego que baja el broker fee al publicar órdenes. Advanced Broker Relations abarata modificarlas."
        ),
        :broker
      ),
      e(
        :tranquility,
        "Tranquility",
        ["TQ", "servidor"],
        gettext("El servidor principal de EVE Online, donde juegan todos los pilotos."),
        nil
      ),
      e(
        :tvs,
        "TVS",
        ["rango"],
        gettext(
          "Puntaje de 0 a 100 que resume cuánto vale la pena un contrato (utilidad × Certeza). De él sale el rango S, A, B, C o D."
        ),
        :tvs
      ),
      e(
        :utc,
        "UTC",
        ["hora EVE"],
        gettext("Hora universal; es la hora oficial del juego (\"hora EVE\")."),
        nil
      ),
      e(
        :vip,
        "Modo VIP",
        ["VIP"],
        gettext(
          "Estado del servidor de EVE en el que solo entra el personal de CCP, por ejemplo tras un parche. Mientras dura, la app no consulta el mercado."
        ),
        :esi_limits
      ),
      e(
        :walk,
        "Walk-the-book",
        ["libro"],
        gettext(
          "Comprar y vender orden por orden, del mejor precio al peor, para saber el precio real de la cantidad que llevás."
        ),
        :walk
      ),
      e(
        :waypoint,
        "Waypoint",
        ["ruta", "autopiloto"],
        gettext(
          "Punto de ruta del autopiloto del juego. \"Fijar ruta\" lo pone en el cliente de EVE."
        ),
        :board
      )
    ]
    |> Enum.sort_by(&String.downcase(&1.term))
  end

  @doc "Término por clave; falla si no existe (se detecta en los tests)."
  @spec fetch!(atom()) :: entry()
  def fetch!(key) do
    Enum.find(entries(), &(&1.key == key)) ||
      raise ArgumentError, "término del glosario desconocido: #{inspect(key)}"
  end

  @doc "Ancla del término en la página Glosario."
  @spec anchor(atom()) :: String.t()
  def anchor(key), do: "g-" <> String.replace(Atom.to_string(key), "_", "-")

  @doc "URL del término en la documentación."
  @spec href(atom()) :: String.t()
  def href(key), do: "/docs/glosario#" <> anchor(fetch!(key).key)

  defp downtime_window do
    {from, to} = GameRules.get(:downtime_window_utc)
    [from: Calendar.strftime(from, "%H:%M"), to: Calendar.strftime(to, "%H:%M")]
  end

  defp e(key, term, aliases, definition, topic),
    do: %{key: key, term: term, aliases: aliases, definition: definition, topic: topic}
end
