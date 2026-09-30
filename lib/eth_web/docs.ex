defmodule EthWeb.Docs do
  @moduledoc """
  Registro del manual integrado (M11): páginas, su orden en el índice y los **temas** a
  los que enlaza la aplicación (RF-11.2, RNF-5.14).

  La interfaz nunca escribe una URL del manual a mano: pide la de un tema
  (`href(:certainty)`), que apunta a una página y un ancla. Un test verifica que cada
  tema apunta a una página existente y a un encabezado que existe en ella (RF-11.4).

  Implementa: RF-11.1, RF-11.2, RF-11.4.
  """

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
