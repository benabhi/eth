defmodule Eth.Sde.GalaxyTest do
  use ExUnit.Case, async: true

  alias Eth.Sde.Galaxy

  # Dos regiones del espacio conocido unidas por un stargate (B1 — C1) y una de agujeros
  # de gusano, que no se dibuja.
  defp systems do
    %{
      1 => %{name: "A1", region_id: 10_000_001, security: 0.9, x: 0.0, z: 0.0, neighbors: [2]},
      2 => %{name: "A2", region_id: 10_000_001, security: 0.5, x: 2.0, z: 0.0, neighbors: [1, 3]},
      3 => %{name: "B1", region_id: 10_000_002, security: 0.1, x: 10.0, z: 4.0, neighbors: [2]},
      4 => %{name: "W1", region_id: 11_000_001, security: -1.0, x: 50.0, z: 50.0, neighbors: []},
      5 => %{name: "S/P", region_id: 10_000_002, security: 0.3, x: nil, z: nil, neighbors: []}
    }
  end

  defp regions, do: %{10_000_001 => %{name: "Alfa"}, 10_000_002 => %{name: "Beta"}}

  test "una región por centro de sus sistemas, unidas si un stargate las cruza" do
    map = Galaxy.regions(systems(), regions())

    assert Enum.map(map.nodes, & &1.name) == ["Alfa", "Beta"]
    assert map.links == [{10_000_001, 10_000_002}]

    [alfa, beta] = map.nodes
    # Beta queda al Este (más a la derecha) y al Norte (más arriba: y menor).
    assert beta.x > alfa.x
    assert beta.y < alfa.y
    # Todo dentro del lienzo.
    for n <- map.nodes,
        do: assert(n.x >= 0 and n.x <= map.width and n.y >= 0 and n.y <= map.height)
  end

  test "los sistemas de una región con su seguridad y los stargates internos" do
    map = Galaxy.region(systems(), 10_000_001, regions(), %{1 => 2})

    assert Enum.map(map.nodes, & &1.name) == ["A1", "A2"]
    assert [%{security: 0.9, stations: 2, exits: []}, a2] = map.nodes
    # A2 es frontera: su stargate sale a Beta, que no es un enlace interno.
    assert %{security: 0.5, stations: 0, exits: [%{id: 10_000_002, name: "Beta"}]} = a2
    assert map.links == [{1, 2}]

    # Cualquier sistema se ubica en el mismo lienzo (las rutas sobre el mapa).
    [a1, _a2] = map.nodes
    assert Galaxy.project(map.frame, systems()[1]) == {a1.x, a1.y}
    assert Galaxy.project(map.frame, systems()[5]) == nil
    assert Galaxy.project(nil, systems()[1]) == nil
  end

  test "sin posiciones no hay mapa" do
    assert %{nodes: [], links: []} = Galaxy.region(systems(), 10_000_009)
    no_positions = Map.new(systems(), fn {id, s} -> {id, %{s | x: nil, z: nil}} end)
    assert %{nodes: [], links: []} = Galaxy.regions(no_positions, regions())
  end
end
