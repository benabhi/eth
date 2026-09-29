defmodule Eth.Engine.BookTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Eth.Engine.Book

  @tax 0.04

  test "recorre el libro mientras el margen neto sea positivo" do
    asks = [{100.0, 10}, {104.0, 10}, {120.0, 10}]
    bids = [{115.0, 5, 1}, {110.0, 30, 1}]

    r = Book.walk(asks, bids, @tax)

    # Netos: 115 × 0.96 = 110.4 ; 110 × 0.96 = 105.6. El ask de 120 nunca rinde.
    assert r.quantity == 20
    assert r.cost == 10 * 100.0 + 10 * 104.0
    assert_in_delta r.revenue, 5 * 110.4 + 15 * 105.6, 1.0e-6
    assert_in_delta r.profit, r.revenue - r.cost, 1.0e-6
    assert_in_delta r.tax, 5 * 115.0 * @tax + 15 * 110.0 * @tax, 1.0e-6
    assert r.asks_used == [{100.0, 10}, {104.0, 10}]
    assert r.bids_used == [{115.0, 5, 1}, {110.0, 15, 1}]
    assert_in_delta r.marginal_margin, 105.6 - 104.0, 1.0e-6
  end

  test "sin cruce rentable no hay operación" do
    r = Book.walk([{100.0, 10}], [{103.0, 10, 1}], @tax)
    assert r.quantity == 0
    assert r.profit == 0.0
    assert r.avg_buy == nil
  end

  test "respeta capital, bodega y valor máximo" do
    asks = [{100.0, 100}]
    bids = [{200.0, 100, 1}]

    assert Book.walk(asks, bids, @tax, %{capital: 1_050.0}).quantity == 10
    assert Book.walk(asks, bids, @tax, %{cargo_m3: 25.0, unit_volume: 5.0}).quantity == 5
    assert Book.walk(asks, bids, @tax, %{max_value: 300.0}).quantity == 3
  end

  test "saltea la orden de compra cuyo volumen mínimo no se puede cubrir" do
    asks = [{100.0, 10}]
    # La mejor exige 50 unidades por transacción y solo hay 10: se usa la siguiente.
    bids = [{130.0, 100, 50}, {120.0, 100, 1}]

    r = Book.walk(asks, bids, @tax)
    assert r.quantity == 10
    assert r.bids_used == [{120.0, 10, 1}]
  end

  ## Propiedades (ERS §8.3)

  defp book_gen do
    gen all(
          asks <- list_of(tuple({float(min: 1.0, max: 200.0), integer(1..50)}), max_length: 8),
          bids <-
            list_of(tuple({float(min: 1.0, max: 250.0), integer(1..50), integer(1..20)}),
              max_length: 8
            ),
          capital <- one_of([constant(:infinity), float(min: 0.0, max: 20_000.0)]),
          cargo <- one_of([constant(:infinity), float(min: 0.0, max: 500.0)]),
          unit_volume <- float(min: 0.1, max: 20.0)
        ) do
      {asks, bids, %{capital: capital, cargo_m3: cargo, unit_volume: unit_volume}}
    end
  end

  property "nunca excede stock ni límites y el beneficio es no negativo" do
    check all({asks, bids, limits} <- book_gen(), max_runs: 400) do
      r = Book.walk(asks, bids, @tax, limits)

      assert r.quantity <= asks |> Enum.map(&elem(&1, 1)) |> Enum.sum()
      assert r.quantity <= bids |> Enum.map(&elem(&1, 1)) |> Enum.sum()
      assert r.profit >= -1.0e-6
      if limits.capital != :infinity, do: assert(r.cost <= limits.capital + 1.0e-6)

      if limits.cargo_m3 != :infinity,
        do: assert(r.quantity * limits.unit_volume <= limits.cargo_m3 + 1.0e-6)

      # Cada orden de compra usada recibe al menos su volumen mínimo.
      for {_price, qty, min_volume} <- r.bids_used, do: assert(qty >= min_volume)
    end
  end

  property "más capital nunca da menos beneficio" do
    check all(
            {asks, bids, _} <- book_gen(),
            a <- float(min: 0.0, max: 10_000.0),
            b <- float(min: 0.0, max: 10_000.0),
            max_runs: 300
          ) do
      {low, high} = Enum.min_max([a, b])
      p_low = Book.walk(asks, bids, @tax, %{capital: low}).profit
      p_high = Book.walk(asks, bids, @tax, %{capital: high}).profit
      assert p_high >= p_low - 1.0e-6
    end
  end
end
