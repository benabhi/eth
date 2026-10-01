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

  describe "resaltados y tachadas que duran por tiempo" do
    test "un resaltado sobrevive a las recargas hasta que vence" do
      h = RowChanges.highlights(nil, %{"a" => :new}, 0)
      assert RowChanges.class_of(h, "a") == "eth-flash-new"

      # Recarga a los 1,5 s sin cambios: sigue igual (la animación no se corta).
      h = RowChanges.highlights(h, %{}, 1_500)
      assert RowChanges.class_of(h, "a") == "eth-flash-new"

      # Vencido el plazo, sale.
      h = RowChanges.highlights(h, %{}, RowChanges.flash_ms(:new))
      assert RowChanges.class_of(h, "a") == nil
    end

    test "un cambio nuevo usa la otra variante para repetir la animación" do
      h = RowChanges.highlights(nil, %{"a" => :up}, 0)
      assert RowChanges.class_of(h, "a") == "eth-flash-up"

      # Mismo tipo con el anterior todavía vigente: no se reinicia.
      assert RowChanges.class_of(RowChanges.highlights(h, %{"a" => :up}, 100), "a") ==
               "eth-flash-up"

      # Otro tipo: clase nueva.
      assert RowChanges.class_of(RowChanges.highlights(h, %{"a" => :down}, 100), "a") ==
               "eth-flash-down"

      # Mismo tipo justo después de vencer: la variante -alt, para que se vea otra vez.
      later = RowChanges.flash_ms(:up) + 1

      assert RowChanges.class_of(RowChanges.highlights(h, %{"a" => :up}, later), "a") ==
               "eth-flash-up-alt"
    end

    test "un reacomodo no tapa un resaltado vigente" do
      h = RowChanges.highlights(nil, %{"a" => :new}, 0)

      assert RowChanges.class_of(RowChanges.highlights(h, %{"a" => :moved}, 100), "a") ==
               "eth-flash-new"
    end

    test "una fila tachada sigue a la vista en las recargas siguientes hasta vencer" do
      previous = RowChanges.ghosts(rows([{"a", 1.0}, {"b", 2.0}]), &%{name: &1.id})

      {shown, lingering, fresh} = RowChanges.with_lingering(rows([{"a", 1.0}]), previous, %{}, 0)

      assert fresh == ["b"]
      assert Enum.map(shown, & &1.id) == ["a", "b"]

      # Recarga a 1 s: "b" ya no está en las filas anteriores, pero sigue tachada.
      previous = RowChanges.ghosts(rows([{"a", 1.0}]), &%{name: &1.id})

      {shown, lingering, fresh} =
        RowChanges.with_lingering(rows([{"a", 1.0}]), previous, lingering, 1_000)

      assert fresh == []
      assert [%{id: "a"}, %{id: "b", expired: true}] = shown

      # Vencida, sale; y si la fila vuelve, deja de estar tachada.
      assert {[%{id: "a"}], %{}, []} =
               RowChanges.with_lingering(rows([{"a", 1.0}]), previous, lingering, 4_000)

      assert {[%{id: "a"}, %{id: "b"}], %{}, []} =
               RowChanges.with_lingering(rows([{"a", 1.0}, {"b", 2.0}]), previous, lingering, 10)
    end

    test "con filtros nuevos no quedan tachadas" do
      assert {[%{id: "a"}], %{}, []} =
               RowChanges.with_lingering([%{id: "a"}], nil, %{"b" => {0, %{}, 9_999}}, 0)
    end
  end
end
