defmodule Eth.Market.RateWindowTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Eth.Market.RateWindow

  test "admite hasta el máximo y después indica cuánto esperar" do
    w = RateWindow.new(2, 60_000)
    {:ok, w} = RateWindow.take(w, 0)
    {:ok, w} = RateWindow.take(w, 10_000)
    assert {:wait, 50_000} = RateWindow.take(w, 10_000)
    assert {:ok, _w} = RateWindow.take(w, 60_000)
    assert RateWindow.count(w, 60_000) == 1
  end

  # CA de RF-1.12: nunca más de `max` requests en ninguna ventana de 60 s.
  property "ninguna ventana de 60 s supera el máximo" do
    check all(
            max <- integer(1..20),
            gaps <- list_of(integer(0..5_000), min_length: 1, max_length: 300)
          ) do
      times = Enum.scan(gaps, &(&1 + &2))

      {taken, _w} =
        Enum.reduce(times, {[], RateWindow.new(max, 60_000)}, fn t, {taken, w} ->
          case RateWindow.take(w, t) do
            {:ok, w} -> {[t | taken], w}
            {:wait, ms} when ms > 0 -> {taken, w}
          end
        end)

      for t <- taken do
        assert Enum.count(taken, &(&1 > t - 60_000 and &1 <= t)) <= max
      end
    end
  end
end
