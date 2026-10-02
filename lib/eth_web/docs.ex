defmodule EthWeb.Docs do
  @moduledoc """
  Registro del manual integrado (M11): páginas, su orden en el índice y los **temas** a
  los que enlaza la aplicación (RF-11.2, RNF-5.14).

  La interfaz nunca escribe una URL del manual a mano: pide la de un tema
  (`href(:certainty)`), que apunta a una página y un ancla. Un test verifica que cada
  tema apunta a una página existente y a un encabezado que existe en ella (RF-11.4).

  Implementa: RF-11.1, RF-11.2, RF-11.4, RNF-5.14.
  """

  use Gettext, backend: EthWeb.Gettext

  # {slug, título, grupo del índice}, en el orden de lectura.
  @pages [
    {"primeros-pasos", "Instalar y registrar tu app de EVE", "Primeros pasos"},
    {"tablon", "El tablón de caza", "El tablón"},
    {"familias", "Directo, Por órdenes y Estación", "El tablón"},
    {"impuestos", "Impuestos y comisiones", "Cómo se calculan los números"},
    {"walk-the-book", "Walk-the-book: cuánto se compra y se vende",
     "Cómo se calculan los números"},
    {"tvs-certeza", "TVS y Certeza", "Cómo se calculan los números"},
    {"anti-scam", "Anti-scam, liquidez y realismo", "Cómo se calculan los números"},
    {"radar", "Radar, peligro y rutas", "En ruta"},
    {"bodega", "Bodega y perfiles de nave", "En ruta"},
    {"viaje", "Viaje activo y registro del cazador", "En ruta"},
    {"ordenes", "Station trading, Listado y tus órdenes", "Trading por órdenes"},
    {"centro-de-control", "Centro de control", "Referencia"},
    {"ajustes", "Ajustes", "Referencia"},
    {"esi", "Límites de ESI y privacidad", "Referencia"},
    {"glosario", "Glosario", "Referencia"},
    {"preguntas", "Preguntas frecuentes", "Referencia"}
  ]

  # Tema => {página, ancla}. Las anclas son los `id` de los encabezados de cada página.
  @topics %{
    first_steps: {"primeros-pasos", "registrar-la-aplicacion"},
    scopes: {"primeros-pasos", "permisos"},
    board: {"tablon", "el-tablon"},
    rank: {"tablon", "rangos"},
    seals: {"tablon", "sellos"},
    danger: {"radar", "peligro"},
    families: {"familias", "las-tres-familias"},
    shortcuts: {"tablon", "atajos"},
    board_age: {"tablon", "antiguedad"},
    no_structures: {"tablon", "sin-estructuras"},
    skills: {"impuestos", "habilidades"},
    book_depth: {"walk-the-book", "lo-que-sigue-en-el-libro"},
    sales_tax: {"impuestos", "sales-tax"},
    broker: {"impuestos", "broker-fee"},
    relist: {"impuestos", "modificar-una-orden"},
    profit: {"walk-the-book", "beneficio"},
    walk: {"walk-the-book", "como-se-recorre-el-libro"},
    range: {"walk-the-book", "venta-por-rango"},
    tvs: {"tvs-certeza", "tvs"},
    certainty: {"tvs-certeza", "certeza"},
    isk_per_hour: {"tvs-certeza", "isk-por-hora"},
    shield: {"anti-scam", "escudo-anti-scam"},
    liquidity: {"anti-scam", "liquidez"},
    realism: {"anti-scam", "precios-realistas"},
    radar: {"radar", "mapa-de-calor"},
    evasive: {"radar", "ruta-evasiva"},
    cargo: {"bodega", "bodega-calculada"},
    ship_profile: {"bodega", "perfiles-de-nave"},
    run: {"viaje", "viaje-activo"},
    hunter_log: {"viaje", "registro-del-cazador"},
    station: {"ordenes", "station-trading"},
    competition: {"ordenes", "competencia"},
    listing: {"ordenes", "listado-y-compra-por-orden"},
    wait: {"ordenes", "espera-estimada"},
    own_orders: {"ordenes", "tus-ordenes"},
    control: {"centro-de-control", "como-leerlo"},
    pollers: {"centro-de-control", "pollers"},
    budgets: {"centro-de-control", "presupuestos-de-esi"},
    history_queue: {"centro-de-control", "cola-de-historial"},
    radar_feed: {"centro-de-control", "feed-del-radar"},
    engine: {"centro-de-control", "motor"},
    pipeline: {"centro-de-control", "pipeline"},
    last_hour: {"centro-de-control", "ultima-hora"},
    live_board: {"tablon", "en-vivo"},
    settings: {"ajustes", "ajustes"},
    esi_limits: {"esi", "limites"},
    privacy: {"esi", "privacidad"},
    glossary: {"glosario", "glosario"}
  }

  @doc "Páginas del manual: `[{slug, título, grupo}]` en orden de lectura."
  @spec pages() :: [{String.t(), String.t(), String.t()}]
  def pages, do: @pages

  @doc "Temas enlazables: `%{tema => {página, ancla}}`."
  @spec topics() :: %{atom() => {String.t(), String.t()}}
  def topics, do: @topics

  @doc "¿Existe la página?"
  @spec page?(String.t()) :: boolean()
  def page?(slug), do: Enum.any?(@pages, &(elem(&1, 0) == slug))

  @doc "Título de una página (`nil` si no existe)."
  @spec title(String.t()) :: String.t() | nil
  def title(slug) do
    case Enum.find(@pages, &(elem(&1, 0) == slug)) do
      {_slug, title, _group} -> title
      nil -> nil
    end
  end

  @doc "URL del manual para un tema (falla si el tema no existe: se detecta en los tests)."
  @spec href(atom()) :: String.t()
  def href(topic) do
    case Map.fetch(@topics, topic) do
      {:ok, {page, anchor}} -> "/docs/#{page}##{anchor}"
      :error -> raise ArgumentError, "tema del manual desconocido: #{inspect(topic)}"
    end
  end

  @doc """
  Resumen breve de un tema, para el "?" que no trae un texto propio (RNF-5.14): ningún
  tooltip queda solo con el enlace. Un test verifica que todos los temas tengan uno.
  """
  @spec summary(atom()) :: String.t()
  def summary(:first_steps),
    do: gettext("Cómo instalar la aplicación y registrar tu propia aplicación de EVE.")

  def summary(:scopes),
    do: gettext("Los permisos que pide la app a EVE y para qué usa cada uno.")

  def summary(:board),
    do: gettext("Cada fila es un contrato: qué comprar, dónde venderlo y cuánto ganás.")

  def summary(:rank),
    do: gettext("La letra resume el TVS: S ≥ 90, A ≥ 75, B ≥ 50, C ≥ 25; el resto, D.")

  def summary(:seals),
    do: gettext("Sellos del contrato: nuevo, en riesgo, sospechoso, ilíquido, estructura…")

  def summary(:danger),
    do: gettext("Riesgo de la ruta según el radar, tu nave y el valor de la carga.")

  def summary(:families),
    do:
      gettext("Directo: comprás y vendés al instante. Por órdenes y Estación: publicás órdenes.")

  def summary(:shortcuts),
    do: gettext("/ buscar · j/k recorrer · Enter abrir · c copiar · w ruta · f congelar.")

  def summary(:board_age),
    do: gettext("Cuánto hace que el contrato está en el tablón; lo recién aparecido, en celeste.")

  def summary(:no_structures),
    do: gettext("Saca del tablón los contratos que pasan por estructuras de jugadores.")

  def summary(:skills),
    do: gettext("Cuánto más dejaría el contrato con más nivel en Accounting o Broker Relations.")

  def summary(:book_depth),
    do: gettext("Órdenes que siguen a las consumidas y beneficio si falla la mejor compra.")

  def summary(:sales_tax),
    do: gettext("Impuesto al vender, más bajo con Accounting.")

  def summary(:broker),
    do: gettext("Comisión por publicar una orden; baja con Broker Relations y los standings.")

  def summary(:relist),
    do: gettext("Cambiar el precio de una orden vuelve a cobrar parte del broker fee.")

  def summary(:profit),
    do: gettext("Lo que cobrás al vender, menos lo que pagás al comprar y los impuestos.")

  def summary(:walk),
    do: gettext("Se compra y se vende orden por orden, del mejor precio al peor.")

  def summary(:range),
    do: gettext("Órdenes de compra con rango: se puede vender desde sistemas cercanos.")

  def summary(:tvs),
    do: gettext("Puntaje 0–100: qué tan bueno es el contrato (utilidad × certeza).")

  def summary(:certainty),
    do: gettext("Qué tan probable es que el contrato salga como se calculó cuando llegues.")

  def summary(:isk_per_hour),
    do: gettext("Beneficio por hora contando los saltos desde tu ubicación.")

  def summary(:shield),
    do: gettext("Detecta órdenes trampa y precios irreales; las SCAM quedan bloqueadas.")

  def summary(:liquidity),
    do: gettext("Si el objeto se opera lo suficiente para venderlo sin esperar.")

  def summary(:realism),
    do: gettext("Precios comparados con la mediana de los últimos días.")

  def summary(:radar),
    do: gettext("Kills en vivo comparadas con lo habitual de cada sistema.")

  def summary(:evasive),
    do: gettext("Ruta que esquiva camps y ganks aunque sea más larga.")

  def summary(:cargo),
    do: gettext("La bodega real de tu nave, calculada con sus módulos y habilidades.")

  def summary(:ship_profile),
    do: gettext("Bodega y clase de evasión guardadas para una nave o un casco.")

  def summary(:run),
    do: gettext("El contrato que estás cazando: etapas, amenazas y resultado real.")

  def summary(:hunter_log),
    do: gettext("Tu historial real de contratos: rango, racha e hitos.")

  def summary(:station),
    do: gettext("Comprar y vender con órdenes propias en la misma estación.")

  def summary(:competition),
    do: gettext("Cuántas órdenes compiten cerca de tu precio: más competencia, menos certeza.")

  def summary(:listing),
    do: gettext("Listado: vendés con una orden en el hub. Compra por orden: comprás con una.")

  def summary(:wait),
    do: gettext("Días estimados hasta que tu orden se ejecute.")

  def summary(:own_orders),
    do: gettext("Tus órdenes abiertas y si otra te superó.")

  def summary(:control),
    do: gettext("Qué descarga la app, cuánto presupuesto de EVE le queda y cómo anda el radar.")

  def summary(:pollers),
    do:
      gettext(
        "Procesos que descargan el mercado de cada región: N1 los hubs, N2 las activas y N3 el resto. Anillo exterior: tiempo hasta datos nuevos; interior: páginas descargadas."
      )

  def summary(:budgets),
    do:
      gettext(
        "Consultas usadas de cada presupuesto de EVE; cerca del límite la app baja el ritmo."
      )

  def summary(:history_queue),
    do: gettext("Historial de precios que se descarga a demanda, con un tope por minuto.")

  def summary(:radar_feed),
    do:
      gettext(
        "Kills en vivo de zKillboard por su feed R2Z2; si se corta, el radar usa solo la línea base."
      )

  def summary(:pipeline),
    do: gettext("El camino de los datos: EVE, memoria, motor, oportunidades y tus pestañas.")

  def summary(:last_hour),
    do:
      gettext("Un punto por minuto de los últimos 60: consultas, errores, tiempos y presupuesto.")

  def summary(:live_board),
    do: gettext("Filas nuevas, mejores, peores y expiradas; cuándo se congela la grilla.")

  def summary(:engine),
    do: gettext("Cuánto tardó cada etapa de la última evaluación del mercado.")

  def summary(:settings),
    do: gettext("Personajes, naves, reglas del juego, radar, mercados y alertas.")

  def summary(:esi_limits),
    do: gettext("Los límites de consultas de EVE y cómo la app los respeta.")

  def summary(:privacy),
    do: gettext("Tus datos quedan en tu máquina; solo se consulta a EVE y a zKillboard.")

  def summary(:glossary),
    do: gettext("Términos de EVE y de la aplicación.")

  @doc "Página anterior y siguiente en el orden de lectura."
  @spec neighbors(String.t()) :: {tuple() | nil, tuple() | nil}
  def neighbors(slug) do
    index = Enum.find_index(@pages, &(elem(&1, 0) == slug))

    {
      if(index && index > 0, do: Enum.at(@pages, index - 1)),
      if(index, do: Enum.at(@pages, index + 1))
    }
  end
end
