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
end
