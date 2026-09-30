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
  end
end
