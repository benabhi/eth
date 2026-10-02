defmodule EthWeb.GalaxyMap do
  @moduledoc """
  Cálculos de presentación del mapa del Centro de control (RF-8.2): tamaño de cada región
  según sus órdenes, calor del radar por región y por sistema, y el arco de la cuenta
  regresiva. Funciones puras; el dibujo (SVG) vive en `EthWeb.ControlLive`.

  - **Calor de una región:** la amenaza más alta entre sus sistemas en alerta, las kills
    de la ventana y cuántos sistemas están en alerta (`Eth.Threat.hot_systems/0`).
  - **Halo:** crece con la amenaza; sin alertas pero con kills, un halo tenue.
  - **Filtros:** resaltar las regiones con el poller en problemas, con calor o con
    oportunidades; el resto se atenúa sin desaparecer (la geografía sigue a la vista).
  - **Oportunidades:** cuántas oportunidades del motor compran y venden en cada región y
    sistema, y el mejor beneficio (`Eth.Engine.all/0`).
  - **Pilotos:** en qué sistema está cada personaje con sesión.
  - **Buscar:** una región o un sistema por nombre (exacto, después por prefijo y por
    parte del nombre).
  - **Rutas:** la ruta abierta desde el tablón (`?route=` con los sistemas) y el camino que
    le falta a cada viaje activo, como tramos entre sistemas consecutivos.

  Implementa: RF-8.2, RF-8.5.
  """

  @typedoc "Calor del radar de una región o un sistema."
  @type heat :: %{threat: float(), kills: non_neg_integer(), alerts: non_neg_integer()}

  @typedoc "Oportunidades que compran (`buy`) y venden (`sell`) en un lugar y la mejor."
  @type opp_stats :: %{buy: non_neg_integer(), sell: non_neg_integer(), best: float()}

  @doc """
  Calor por región a partir de los sistemas con kills. `region_of` devuelve la región de
  un sistema (o `nil` si no se conoce).
  """
  @spec region_heat([map()], (pos_integer() -> pos_integer() | nil)) :: %{
          pos_integer() => heat()
        }
  def region_heat(hot, region_of) do
    Enum.reduce(hot, %{}, fn h, acc ->
      case region_of.(h.system_id) do
        nil -> acc
        region_id -> Map.update(acc, region_id, system_heat(h), &merge(&1, system_heat(h)))
      end
    end)
  end

  @doc "Calor de un sistema con kills (la amenaza solo cuenta si hay alerta)."
  @spec system_heat(map()) :: heat()
  def system_heat(h) do
    alert? = Map.get(h, :alert) == true

    %{
      threat: if(alert?, do: Map.get(h, :threat, 0.0) / 1, else: 0.0),
      kills: Map.get(h, :kills, 0),
      alerts: if(alert?, do: 1, else: 0)
    }
  end

  defp merge(a, b),
    do: %{threat: max(a.threat, b.threat), kills: a.kills + b.kills, alerts: a.alerts + b.alerts}

  @doc """
  Radio de una región en el lienzo: entre `min` y `max` según la raíz de sus órdenes
  frente a la región con más (la raíz evita que The Forge tape a todas).
  """
  @spec node_radius(non_neg_integer() | nil, pos_integer(), number(), number()) :: float()
  def node_radius(orders, max_orders, min_r \\ 6, max_r \\ 15)
  def node_radius(nil, _max_orders, min_r, _max_r), do: min_r / 1

  def node_radius(orders, max_orders, min_r, max_r) do
    ratio = :math.sqrt(orders / max(max_orders, 1))
    Float.round(min_r + (max_r - min_r) * min(ratio, 1.0), 1)
  end

  @doc "Radio del halo del radar alrededor de un punto de radio `r` (`nil` sin calor)."
  @spec halo_radius(heat() | nil, number()) :: float() | nil
  def halo_radius(nil, _r), do: nil
  def halo_radius(%{alerts: 0, kills: 0}, _r), do: nil
  def halo_radius(%{alerts: 0}, r), do: Float.round(r + 4.0, 1)
  def halo_radius(%{threat: threat}, r), do: Float.round(r + 6 + 14 * min(threat, 1.0), 1)

  @doc "`stroke-dasharray` de un arco que cubre la fracción `value` de un círculo de radio `r`."
  @spec arc_dash(number(), number()) :: String.t()
  def arc_dash(value, r) do
    circumference = 2 * :math.pi() * r
    filled = circumference * min(max(value, 0.0), 1.0)
    "#{Float.round(filled, 2)} #{Float.round(circumference, 2)}"
  end

  @doc """
  ¿La región pasa el filtro del mapa? `:all` todas; `:problems` las de poller con un
  estado que pide atención (no fresco ni descargando); `:heat` las que tienen kills;
  `:opps` las que tienen oportunidades para comprar o vender. `key` es el estado visual
  del poller (`nil` si la región no se sigue).
  """
  @spec region_matches?(
          :all | :problems | :heat | :opps,
          atom() | nil,
          heat() | nil,
          opp_stats() | nil
        ) :: boolean()
  def region_matches?(filter, key, heat, opps \\ nil)
  def region_matches?(:all, _key, _heat, _opps), do: true
  def region_matches?(:problems, key, _heat, _opps), do: key not in [nil, :fresh, :fetching]
  def region_matches?(:heat, _key, heat, _opps), do: heat != nil and heat.kills > 0
  def region_matches?(:opps, _key, _heat, opps), do: opps != nil and opps.buy + opps.sell > 0

  @doc "Clase de relleno de un sistema coloreado por calor: alerta, kills o nada."
  @spec heat_class(heat() | nil) :: String.t()
  def heat_class(%{alerts: alerts}) when alerts > 0, do: "fill-error"
  def heat_class(%{kills: kills}) when kills > 0, do: "fill-warning"
  def heat_class(_heat), do: "fill-base-content/25"

  @doc """
  Oportunidades por región y por sistema: las que compran ahí (`buy`, por el origen), las
  que venden ahí (`sell`, por el destino) y el mejor beneficio entre todas (`best`).
  """
  @spec opportunity_stats([map()]) :: %{
          regions: %{pos_integer() => opp_stats()},
          systems: %{pos_integer() => opp_stats()}
        }
  def opportunity_stats(opps) do
    Enum.reduce(opps, %{regions: %{}, systems: %{}}, fn opp, acc ->
      profit = opp.profit || 0.0

      acc
      |> bump(:regions, opp.origin.region_id, :buy, profit)
      |> bump(:regions, opp.destination.region_id, :sell, profit)
      |> bump(:systems, opp.origin.system_id, :buy, profit)
      |> bump(:systems, opp.destination.system_id, :sell, profit)
    end)
  end

  defp bump(acc, _scope, nil, _side, _profit), do: acc

  defp bump(acc, scope, id, side, profit) do
    empty = %{buy: 0, sell: 0, best: profit / 1}

    update_in(acc, [scope], fn places ->
      Map.update(places, id, Map.put(empty, side, 1), fn stats ->
        %{stats | best: max(stats.best, profit / 1)} |> Map.update!(side, &(&1 + 1))
      end)
    end)
  end

  @doc "Personajes por sistema según la ubicación de su sesión (`Eth.Characters.Sessions`)."
  @spec pilots([map()]) :: %{pos_integer() => [String.t()]}
  def pilots(sessions) do
    for s <- sessions,
        system_id = get_in(s, [:context, :location, :solar_system_id]),
        is_integer(system_id),
        reduce: %{} do
      acc -> Map.update(acc, system_id, [pilot_name(s)], &(&1 ++ [pilot_name(s)]))
    end
  end

  defp pilot_name(%{name: name}) when is_binary(name), do: name
  defp pilot_name(session), do: Integer.to_string(session.id)

  # Una ruta del tablón cruza el universo de punta a punta en menos de 200 saltos.
  @max_route 300

  @doc """
  Sistemas de una ruta pasada por la URL (`"30000142,30000144"`): solo IDs válidos, sin
  repetir uno seguido de sí mismo y con un tope de #{@max_route}.
  """
  @spec parse_route(String.t() | nil) :: [pos_integer()]
  def parse_route(nil), do: []

  def parse_route(text) when is_binary(text) do
    text
    |> String.split(",", trim: true)
    |> Enum.take(@max_route)
    |> Enum.flat_map(fn part ->
      case Integer.parse(String.trim(part)) do
        {id, ""} when id > 0 -> [id]
        _ -> []
      end
    end)
    |> Enum.dedup()
  end

  @doc "Tramos de una ruta (sistemas consecutivos) con los dos extremos en `points`."
  @spec route_links([pos_integer()], map()) :: [{pos_integer(), pos_integer()}]
  def route_links(path, points) do
    path
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.filter(fn [a, b] -> Map.has_key?(points, a) and Map.has_key?(points, b) end)
    |> Enum.map(&List.to_tuple/1)
  end

  @doc """
  Lugares por los que pasa una ruta, sin repetir seguidos: `place` lleva cada sistema a su
  región (universo) o lo deja igual. Los sistemas sin lugar se saltean.
  """
  @spec route_places([pos_integer()], (pos_integer() -> pos_integer() | nil)) :: [pos_integer()]
  def route_places(path, place) do
    path |> Enum.map(place) |> Enum.reject(&is_nil/1) |> Enum.dedup()
  end

  @doc """
  Dónde una ruta entra o sale del mapa a la vista (una región): `{:out, adentro, afuera}`
  si el siguiente sistema queda fuera, `{:in, adentro, afuera}` si viene de afuera.
  """
  @spec route_crossings([pos_integer()], map()) ::
          [{:in | :out, pos_integer(), pos_integer()}]
  def route_crossings(path, points) do
    path
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn [a, b] ->
      case {Map.has_key?(points, a), Map.has_key?(points, b)} do
        {true, false} -> [{:out, a, b}]
        {false, true} -> [{:in, b, a}]
        _ -> []
      end
    end)
  end

  @doc """
  Paradas de una ruta para marcar: inicio (el primer sistema), compra (`stop`, si hay) y
  venta (el último). El inicio no se marca si ya es la compra o la venta.
  """
  @spec route_stops(%{path: [pos_integer()], stop: pos_integer() | nil}) ::
          [{:start | :buy | :sell, pos_integer()}]
  def route_stops(%{path: [first | _] = path} = route) do
    last = List.last(path)
    stop = route[:stop]
    start = if first not in [stop, last], do: [{:start, first}], else: []
    buy = if stop, do: [{:buy, stop}], else: []
    start ++ buy ++ [{:sell, last}]
  end

  def route_stops(_route), do: []

  @doc """
  Busca un punto del mapa por nombre sin distinguir mayúsculas: primero el nombre exacto,
  después el que empieza así y por último el que lo contiene (`nil` si no hay).
  """
  @spec find([map()], String.t()) :: map() | nil
  def find(nodes, query) do
    wanted = query |> String.trim() |> String.downcase()

    named =
      nodes
      |> Enum.sort_by(&String.length(&1.name))
      |> Enum.map(&{String.downcase(&1.name), &1})

    if wanted != "" do
      [&(&1 == wanted), &String.starts_with?(&1, wanted), &String.contains?(&1, wanted)]
      |> Enum.find_value(fn matches ->
        Enum.find_value(named, fn {name, node} -> matches.(name) && node end)
      end)
    end
  end
end
