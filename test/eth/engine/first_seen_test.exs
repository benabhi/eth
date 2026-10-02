defmodule Eth.Engine.FirstSeenTest do
  use ExUnit.Case, async: true

  alias Eth.Engine.FirstSeen

  defp item(id), do: %{id: id, first_seen: nil}

  test "una oportunidad que sigue conserva su momento; una nueva toma el actual" do
    {items, seen} = FirstSeen.stamp([item("a"), item("b")], %{"a" => 100}, 500)

    assert Enum.map(items, & &1.first_seen) == [100, 500]
    assert seen == %{"a" => 100, "b" => 500}
  end

  test "las que desaparecen salen del mapa y, si vuelven, empiezan de nuevo" do
    {_items, seen} = FirstSeen.stamp([item("b")], %{"a" => 100, "b" => 200}, 500)
    assert seen == %{"b" => 200}

    {[again], _seen} = FirstSeen.stamp([item("a")], seen, 900)
    assert again.first_seen == 900
  end

  test "minutos en el tablón y cota inferior para lo que estaba al arrancar" do
    now = DateTime.from_unix!(10_000)

    assert FirstSeen.age(10_000 - 720, 5_000, now) == {12, false}
    # Ya estaba en la primera evaluación: "al menos".
    assert FirstSeen.age(5_000, 5_000, now) == {83, true}
    assert FirstSeen.age(nil, 5_000, now) == nil
    assert FirstSeen.age(10_000, nil, now) == {0, false}
  end
end
