defmodule EthWeb.GalaxyMapTest do
  use ExUnit.Case, async: true

  alias EthWeb.GalaxyMap

  @regions %{1 => 10_000_002, 2 => 10_000_002, 3 => 10_000_030}

  test "el calor de una región junta sus sistemas: amenaza máxima, kills y alertas" do
    hot = [
      %{system_id: 1, alert: true, threat: 0.4, kills: 3},
      %{system_id: 2, alert: true, threat: 0.9, kills: 5},
      %{system_id: 3, alert: false, threat: 0.7, kills: 1},
      %{system_id: 99, alert: true, threat: 1.0, kills: 9}
    ]

    heat = GalaxyMap.region_heat(hot, &Map.get(@regions, &1))

    assert heat[10_000_002] == %{threat: 0.9, kills: 8, alerts: 2}
    # Sin alerta, la amenaza no cuenta: solo las kills.
    assert heat[10_000_030] == %{threat: 0.0, kills: 1, alerts: 0}
    # Un sistema sin región conocida no suma.
    assert map_size(heat) == 2
  end

  test "el tamaño de una región crece con la raíz de sus órdenes" do
    assert GalaxyMap.node_radius(400_000, 400_000) == 15.0
    assert GalaxyMap.node_radius(100_000, 400_000) == 10.5
    assert GalaxyMap.node_radius(nil, 400_000) == 6.0
    assert GalaxyMap.node_radius(0, 400_000) == 6.0
  end

  test "el halo crece con la amenaza; sin alertas pero con kills, uno tenue" do
    assert GalaxyMap.halo_radius(nil, 10) == nil
    assert GalaxyMap.halo_radius(%{threat: 0.0, kills: 0, alerts: 0}, 10) == nil
    assert GalaxyMap.halo_radius(%{threat: 0.0, kills: 2, alerts: 0}, 10) == 14.0
    assert GalaxyMap.halo_radius(%{threat: 0.5, kills: 4, alerts: 1}, 10) == 23.0
  end

  test "arco de la cuenta regresiva" do
    assert GalaxyMap.arc_dash(0.5, 10) == "31.42 62.83"
    assert GalaxyMap.arc_dash(2.0, 10) == "62.83 62.83"
  end

  test "filtros del mapa: con problemas o con calor" do
    assert GalaxyMap.region_matches?(:all, nil, nil)
    assert GalaxyMap.region_matches?(:problems, :degraded, nil)
    refute GalaxyMap.region_matches?(:problems, :fresh, nil)
    refute GalaxyMap.region_matches?(:problems, :fetching, nil)
    refute GalaxyMap.region_matches?(:problems, nil, nil)
    assert GalaxyMap.region_matches?(:heat, :fresh, %{threat: 0.0, kills: 1, alerts: 0})
    refute GalaxyMap.region_matches?(:heat, :fresh, nil)
    assert GalaxyMap.region_matches?(:opps, nil, nil, %{buy: 0, sell: 2, best: 1.0})
    refute GalaxyMap.region_matches?(:opps, :fresh, nil, nil)
  end

  defp opp(origin, destination, profit) do
    %{
      origin: %{region_id: elem(origin, 0), system_id: elem(origin, 1)},
      destination: %{region_id: elem(destination, 0), system_id: elem(destination, 1)},
      profit: profit
    }
  end

  test "oportunidades por región y sistema: compran en el origen y venden en el destino" do
    stats =
      GalaxyMap.opportunity_stats([
        opp({10, 1}, {20, 2}, 5.0e6),
        opp({10, 1}, {10, 3}, 9.0e6),
        opp({20, 2}, {10, 1}, 1.0e6)
      ])

    assert stats.regions[10] == %{buy: 2, sell: 2, best: 9.0e6}
    assert stats.regions[20] == %{buy: 1, sell: 1, best: 5.0e6}
    assert stats.systems[1] == %{buy: 2, sell: 1, best: 9.0e6}
    assert stats.systems[3] == %{buy: 0, sell: 1, best: 9.0e6}
  end

  test "pilotos por sistema según la ubicación de su sesión" do
    sessions = [
      %{id: 1, name: "Ana", context: %{location: %{solar_system_id: 30_000_142}}},
      %{id: 2, name: "Beto", context: %{location: %{solar_system_id: 30_000_142}}},
      %{id: 3, name: "Ciro", context: %{}}
    ]

    assert GalaxyMap.pilots(sessions) == %{30_000_142 => ["Ana", "Beto"]}
  end

  test "una ruta por la URL: solo IDs válidos y con tope" do
    assert GalaxyMap.parse_route("30000142, 30000144,x,-3,30000144,30005196") ==
             [30_000_142, 30_000_144, 30_005_196]

    assert GalaxyMap.parse_route(nil) == []
    assert length(GalaxyMap.parse_route(Enum.map_join(1..500, ",", &to_string/1))) == 300
  end

  test "tramos de una ruta dentro del mapa" do
    points = %{1 => %{}, 2 => %{}, 3 => %{}}
    assert GalaxyMap.route_links([1, 2, 9, 3, 1], points) == [{1, 2}, {3, 1}]
    assert GalaxyMap.route_links([1], points) == []
  end

  test "una ruta por regiones: sin repetir seguidas ni sistemas sin lugar" do
    region = %{1 => 10, 2 => 10, 3 => 20, 4 => nil, 5 => 10}
    assert GalaxyMap.route_places([1, 2, 3, 4, 5], &region[&1]) == [10, 20, 10]
  end

  test "entradas y salidas de una ruta en la región a la vista" do
    points = %{2 => %{}, 3 => %{}}

    assert GalaxyMap.route_crossings([1, 2, 3, 4, 3, 5], points) ==
             [{:in, 2, 1}, {:out, 3, 4}, {:in, 3, 4}, {:out, 3, 5}]

    assert GalaxyMap.route_crossings([2, 3], points) == []
  end

  test "paradas de una ruta: inicio, compra y venta" do
    assert GalaxyMap.route_stops(%{path: [1, 2, 3, 4], stop: 2}) ==
             [start: 1, buy: 2, sell: 4]

    # Ya en la compra, o con la carga comprada (sin compra): sin inicio repetido.
    assert GalaxyMap.route_stops(%{path: [2, 3, 4], stop: 2}) == [buy: 2, sell: 4]
    assert GalaxyMap.route_stops(%{path: [3, 4], stop: nil}) == [start: 3, sell: 4]
    assert GalaxyMap.route_stops(%{path: [], stop: nil}) == []
  end

  test "buscar por nombre: exacto, por prefijo y por parte" do
    nodes = [
      %{id: 1, name: "The Forge"},
      %{id: 2, name: "Forge Minor"},
      %{id: 3, name: "Lonetrek"}
    ]

    assert GalaxyMap.find(nodes, "forge minor").id == 2
    assert GalaxyMap.find(nodes, " lone").id == 3
    assert GalaxyMap.find(nodes, "forge").id == 2
    assert GalaxyMap.find(nodes, "the f").id == 1
    assert GalaxyMap.find(nodes, "trek").id == 3
    assert GalaxyMap.find(nodes, "zz") == nil
    assert GalaxyMap.find(nodes, "  ") == nil
  end

  test "color de un sistema por calor" do
    assert GalaxyMap.heat_class(%{threat: 0.8, kills: 3, alerts: 1}) == "fill-error"
    assert GalaxyMap.heat_class(%{threat: 0.0, kills: 2, alerts: 0}) == "fill-warning"
    assert GalaxyMap.heat_class(nil) == "fill-base-content/25"
  end
end
