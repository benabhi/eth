defmodule Eth.Routing.GraphTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Eth.Routing.Graph

  @opts [root: 1, excluded_region_ids: [99], highsec_min: 0.45]

  # Mapa de prueba (IDs chicos = K-space):
  #
  #   1(hs) — 2(hs) — 3(hs) — 4(hs)
  #   |                        |
  #   5(ls 0.4) ———————————— 4          → Rápida 1→4 = 2 (por 5), Segura 1→4 = 3
  #   6(hs, región excluida 99) — 1     → fuera del grafo
  #   7(hs) aislado                     → fuera del grafo (otra componente)
  #   31000001 (J-space) — 3            → fuera del grafo
  #   8(ns) — 4                         → alcanzable solo en Rápida
  defp systems do
    %{
      1 => sys(10, 0.9, [2, 5, 6]),
      2 => sys(10, 0.8, [1, 3]),
      3 => sys(10, 0.7, [2, 4, 31_000_001]),
      4 => sys(10, 0.5, [3, 5, 8]),
      5 => sys(10, 0.4, [1, 4]),
      6 => sys(99, 0.9, [1]),
      7 => sys(10, 1.0, []),
      8 => sys(11, -0.3, [4]),
      31_000_001 => sys(11_000_001, -1.0, [3])
    }
  end

  defp sys(region, sec, neighbors), do: %{region_id: region, security: sec, neighbors: neighbors}

  setup_all do
    {:ok, graph: Graph.build(systems(), @opts)}
  end

  test "solo incluye la componente principal de K-space sin regiones excluidas", %{graph: g} do
    assert g.n == 6
    assert Enum.all?([1, 2, 3, 4, 5, 8], &Graph.routable?(g, &1))
    refute Graph.routable?(g, 6)
    refute Graph.routable?(g, 7)
    refute Graph.routable?(g, 31_000_001)
  end

  test "Rápida usa el camino más corto aunque pase por lowsec", %{graph: g} do
    assert Graph.distance(g, 1, 4, :shortest) == 2
    assert Graph.path(g, 1, 4, :shortest) == [1, 5, 4]
    assert Graph.distance(g, 1, 8, :shortest) == 3
  end

  test "Segura solo pasa por highsec y no llega a destinos fuera de highsec", %{graph: g} do
    assert Graph.distance(g, 1, 4, :secure) == 3
    assert Graph.path(g, 1, 4, :secure) == [1, 2, 3, 4]
    assert Graph.distance(g, 1, 8, :secure) == nil
    assert Graph.distance(g, 1, 5, :secure) == nil
  end

  test "distancia a sí mismo y sistemas desconocidos", %{graph: g} do
    assert Graph.distance(g, 3, 3, :shortest) == 0
    assert Graph.path(g, 3, 3, :shortest) == [3]
    assert Graph.distance(g, 1, 7, :shortest) == nil
    assert Graph.distance(g, 1, 12_345, :shortest) == nil
    assert Graph.path(g, 1, 6, :shortest) == nil
  end

  test "evita sistemas en caminos concretos", %{graph: g} do
    assert Graph.path(g, 1, 4, :shortest, [5]) == [1, 2, 3, 4]
    assert Graph.path(g, 1, 4, :shortest, [5, 3]) == nil
    # El origen o destino evitado sigue siendo válido.
    assert Graph.path(g, 1, 5, :shortest, [5]) == [1, 5]
  end

  ## Propiedades (ERS §11.2): simetría, Segura ≥ Rápida, desigualdad triangular y
  ## coherencia entre matriz y camino concreto.

  defp graph_gen do
    gen all(
          n <- integer(2..14),
          edges <- list_of(tuple({integer(1..n), integer(1..n)}), max_length: n * 3),
          secs <- list_of(float(min: -1.0, max: 1.0), length: n)
        ) do
      adjacency =
        Enum.reduce(edges, Map.new(1..n, &{&1, []}), fn
          {a, a}, acc -> acc
          {a, b}, acc -> acc |> Map.update!(a, &[b | &1]) |> Map.update!(b, &[a | &1])
        end)

      systems =
        for {id, sec} <- Enum.zip(1..n, secs), into: %{} do
          {id, sys(1, sec, Enum.uniq(adjacency[id]))}
        end

      Graph.build(systems, @opts)
    end
  end

  property "las distancias cumplen las invariantes del ruteo" do
    check all(g <- graph_gen(), max_runs: 150) do
      ids = Tuple.to_list(g.ids)

      for a <- ids, b <- ids do
        short_ab = Graph.distance(g, a, b, :shortest)
        secure_ab = Graph.distance(g, a, b, :secure)

        assert short_ab == Graph.distance(g, b, a, :shortest)
        assert secure_ab == Graph.distance(g, b, a, :secure)

        # Es la componente conexa: en Rápida todo es alcanzable.
        assert is_integer(short_ab)
        if secure_ab, do: assert(secure_ab >= short_ab)

        path = Graph.path(g, a, b, :shortest)
        assert length(path) - 1 == short_ab
        assert hd(path) == a and List.last(path) == b

        for c <- ids do
          assert short_ab <=
                   Graph.distance(g, a, c, :shortest) + Graph.distance(g, c, b, :shortest)
        end
      end
    end
  end
end
