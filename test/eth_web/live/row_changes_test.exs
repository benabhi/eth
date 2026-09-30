defmodule EthWeb.RowChangesTest do
  use ExUnit.Case, async: true

  alias EthWeb.RowChanges

  defp rows(pairs), do: Enum.map(pairs, fn {id, profit} -> %{id: id, profit: profit} end)

  test "sin nada conocido (primera carga o filtros nuevos) no resalta nada" do
    assert {%{}, %{"a" => 10.0}} = RowChanges.diff(nil, rows([{"a", 10.0}]), & &1.profit)
  end

  test "marca las nuevas y las que mejoraron o empeoraron más del 1 %" do
    known = %{"a" => 100.0, "b" => 100.0, "c" => 100.0}
    new_rows = rows([{"a", 100.5}, {"b", 120.0}, {"c", 80.0}, {"d", 5.0}])

    {changes, known} = RowChanges.diff(known, new_rows, & &1.profit)

    assert changes == %{"b" => :up, "c" => :down, "d" => :new}
    assert known["d"] == 5.0
    assert RowChanges.class(:new) == "eth-flash-new"
    assert RowChanges.class(nil) == nil
    # En la carga siguiente la variante cambia: la animación se repite.
    assert RowChanges.class(:up, 1) == "eth-flash-up-alt"
  end

  test "con el mismo beneficio, un cambio de puntaje de 2 puntos o más también se resalta" do
    known = %{"a" => {100.0, 70}, "b" => {100.0, 70}, "c" => {100.0, 70}}
    rows = [%{id: "a", v: {100.0, 73}}, %{id: "b", v: {100.0, 69}}, %{id: "c", v: {100.0, 67}}]

    {changes, _known} = RowChanges.diff(known, rows, & &1.v)

    # a sube 3 (verde), b baja 1 (ruido: nada), c baja 3 (rojo).
    assert changes == %{"a" => :up, "c" => :down}
  end

  test "se marca como movida solo la fila que cambió su orden frente a las demás" do
    previous = RowChanges.ghosts(Enum.map(~w(a b c d e), &%{id: &1}), &%{name: &1.id})
    rows = fn ids -> Enum.map(ids, &%{id: &1}) end

    # e salta arriba: solo e, no las que pasó.
    assert RowChanges.with_moved(%{}, previous, rows.(~w(e a b c d))) == %{"e" => :moved}
    # Intercambio de dos vecinas: una sola marcada.
    assert map_size(RowChanges.with_moved(%{}, previous, rows.(~w(b a c d e)))) == 1
    # Entra una fila nueva arriba: las demás solo se corren, ninguna se marca.
    assert RowChanges.with_moved(%{}, previous, rows.(~w(x a b c d e))) == %{}
    # Un resaltado propio no se pisa.
    assert RowChanges.with_moved(%{"e" => :up}, previous, rows.(~w(e a b c d))) == %{"e" => :up}
    assert RowChanges.class(:moved, 1) == "eth-flash-moved-alt"
  end

  test "las filas que desaparecieron vuelven tachadas en su posición anterior" do
    previous = RowChanges.ghosts(rows([{"a", 1.0}, {"b", 2.0}, {"c", 3.0}]), &%{name: &1.id})

    {shown, expired} =
      RowChanges.with_expired(rows([{"a", 1.0}, {"c", 3.0}, {"d", 4.0}]), previous)

    assert expired == ["b"]
    assert Enum.map(shown, & &1.id) == ["a", "b", "c", "d"]
    assert %{id: "b", expired: true, name: "b"} = Enum.at(shown, 1)
  end

  test "sin nada que comparar (primera carga o filtros nuevos) no hay expiradas" do
    assert {[%{id: "a"}], []} = RowChanges.with_expired([%{id: "a"}], nil)
  end
end
