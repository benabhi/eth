defmodule Eth.Engine.Book do
  @moduledoc """
  Recorrido del libro de órdenes (walk-the-book) para el arbitraje instantáneo
  (RF-4.4, ERS §8.3). Función pura.

  Consume las órdenes de venta del origen de menor a mayor precio contra las órdenes de
  compra elegibles de mayor a menor, mientras el margen neto unitario
  (`bid × (1 − tax) − ask`) sea al menos `min_unit_margin` y no se excedan capital,
  bodega ni valor máximo de carga.

  `min_volume`: una orden de compra exige vender al menos esa cantidad en una sola
  transacción. Antes de usarla se calcula cuánto se le podría vender como máximo con lo
  que queda; si no alcanza el mínimo, se saltea (trampa de volumen mínimo).

  Implementa: RF-4.4, RF-4.6.
  """

  @type ask :: {price :: float(), quantity :: pos_integer()}
  @type bid :: {price :: float(), quantity :: pos_integer(), min_volume :: pos_integer()}

  @type limits :: %{
          optional(:capital) => number() | :infinity,
          optional(:cargo_m3) => number() | :infinity,
          optional(:max_value) => number() | :infinity,
          optional(:unit_volume) => number(),
          optional(:min_unit_margin) => number()
        }

  @type result :: %{
          quantity: non_neg_integer(),
          cost: float(),
          revenue: float(),
          tax: float(),
          profit: float(),
          avg_buy: float() | nil,
          avg_sell: float() | nil,
          marginal_margin: float() | nil,
          asks_used: [ask()],
          bids_used: [bid()]
        }

  @doc """
  Recorre el libro. `asks` ascendente por precio, `bids` descendente, `tax` en fracción
  (0.042 = 4,2 %). Las listas desordenadas se ordenan.
  """
  @spec walk([ask()], [bid()], float(), limits()) :: result()
  def walk(asks, bids, tax, limits \\ %{}) do
    limits = normalize(limits)
    asks = Enum.sort_by(asks, &elem(&1, 0))
    bids = Enum.sort_by(bids, &elem(&1, 0), :desc)

    state = %{
      quantity: 0,
      cost: 0.0,
      revenue: 0.0,
      gross: 0.0,
      marginal: nil,
      asks_used: %{},
      bids_used: []
    }

    state = consume_bids(asks, bids, tax, limits, state)
    result(state)
  end

  defp normalize(limits) do
    %{
      capital: Map.get(limits, :capital, :infinity),
      cargo_m3: Map.get(limits, :cargo_m3, :infinity),
      max_value: Map.get(limits, :max_value, :infinity),
      unit_volume: Map.get(limits, :unit_volume, 0.0),
      min_unit_margin: Map.get(limits, :min_unit_margin, 0.01)
    }
  end

  defp consume_bids(_asks, [], _tax, _limits, state), do: state
  defp consume_bids([], _bids, _tax, _limits, state), do: state

  defp consume_bids(asks, [{bid_price, bid_qty, min_volume} | rest_bids], tax, limits, state) do
    net = bid_price * (1 - tax)
    feasible = feasible_units(asks, net, bid_qty, limits, state)

    cond do
      feasible == 0 ->
        # Ni una unidad rinde contra esta orden: tampoco contra las de menor precio.
        state

      feasible < min_volume ->
        consume_bids(asks, rest_bids, tax, limits, state)

      true ->
        {asks, state} = sell_to_bid(asks, {bid_price, net}, feasible, state)
        state = %{state | bids_used: [{bid_price, feasible, min_volume} | state.bids_used]}
        consume_bids(asks, rest_bids, tax, limits, state)
    end
  end

  # Cuántas unidades se le pueden vender a esta orden respetando margen, stock y límites.
  defp feasible_units(asks, net, bid_qty, limits, state) do
    asks
    |> Enum.reduce_while(
      {0, state.cost, state.quantity},
      &feasible_step(&1, &2, net, bid_qty, limits)
    )
    |> elem(0)
    |> max(0)
  end

  defp feasible_step({price, _qty}, acc, net, _bid_qty, limits)
       when net - price < limits.min_unit_margin,
       do: {:halt, acc}

  defp feasible_step({price, qty}, {units, cost, total}, _net, bid_qty, limits) do
    take = Enum.min([qty, bid_qty - units, affordable(price, cost, total, limits)])
    acc = {units + take, cost + take * price, total + take}
    if take < qty or units + take == bid_qty, do: {:halt, acc}, else: {:cont, acc}
  end

  # Unidades que entran dado capital, bodega y valor máximo ya comprometidos.
  defp affordable(price, cost, total, limits) do
    by_capital = units_by_money(limits.capital, cost, price)
    by_value = units_by_money(limits.max_value, cost, price)

    by_cargo =
      cond do
        limits.cargo_m3 == :infinity -> :infinity
        limits.unit_volume <= 0 -> :infinity
        true -> floor((limits.cargo_m3 - total * limits.unit_volume) / limits.unit_volume)
      end

    [by_capital, by_value, by_cargo]
    |> Enum.reject(&(&1 == :infinity))
    |> Enum.min(fn -> 1_000_000_000_000 end)
    |> max(0)
  end

  defp units_by_money(:infinity, _cost, _price), do: :infinity
  defp units_by_money(money, cost, price), do: floor((money - cost) / price)

  # Consume `units` de las órdenes de venta más baratas contra una orden de compra.
  defp sell_to_bid(asks, _bid, 0, state), do: {asks, state}

  defp sell_to_bid([{price, qty} | rest], {bid_price, net} = bid, units, state) do
    take = min(qty, units)

    state = %{
      state
      | quantity: state.quantity + take,
        cost: state.cost + take * price,
        revenue: state.revenue + take * net,
        gross: state.gross + take * bid_price,
        marginal: net - price,
        asks_used: Map.update(state.asks_used, price, take, &(&1 + take))
    }

    rest = if take < qty, do: [{price, qty - take} | rest], else: rest
    sell_to_bid(rest, bid, units - take, state)
  end

  defp result(%{quantity: 0}) do
    %{
      quantity: 0,
      cost: 0.0,
      revenue: 0.0,
      tax: 0.0,
      profit: 0.0,
      avg_buy: nil,
      avg_sell: nil,
      marginal_margin: nil,
      asks_used: [],
      bids_used: []
    }
  end

  defp result(state) do
    %{
      quantity: state.quantity,
      cost: state.cost,
      revenue: state.revenue,
      tax: state.gross - state.revenue,
      profit: state.revenue - state.cost,
      avg_buy: state.cost / state.quantity,
      avg_sell: state.gross / state.quantity,
      marginal_margin: state.marginal,
      asks_used: state.asks_used |> Enum.sort_by(&elem(&1, 0)),
      bids_used: Enum.reverse(state.bids_used)
    }
  end
end
