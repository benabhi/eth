defmodule Eth.Engine.StationTrading do
  @moduledoc """
  Cálculo del station trading (RF-4.16, ERS §8.4). Funciones puras.

  Con el libro de la estación (sin las órdenes propias del piloto):

      precio_compra = outbid(mejor_bid)            # superar la mejor compra
      precio_venta  = undercut(mejor_ask)          # superar la mejor venta
      costo_u       = precio_compra × (1 + broker)
      ingreso_u     = precio_venta × (1 − sales_tax − broker)
      margen_u      = ingreso_u − costo_u          # margen % = margen_u / costo_u

  El **plan** fija la cantidad objetivo por día: el menor entre `participación ×
  volumen diario de 7 días` y lo que alcanza el capital (el escrow de la compra es el
  100 %). El beneficio por día es una **estimación**: la Certeza lo pondera por la
  competencia (órdenes dentro de ±banda del precio sugerido en cada lado), la frescura
  de los datos y el escudo anti-scam.
  """

  alias Eth.Engine.{Fees, OrderRules}
  alias Eth.GameRules

  @type quote_t :: %{
          best_bid: float(),
          best_ask: float(),
          buy_price: float(),
          sell_price: float(),
          unit_cost: float(),
          unit_revenue: float(),
          unit_margin: float(),
          margin_pct: float(),
          competition: %{bids: non_neg_integer(), asks: non_neg_integer()}
        }

  @doc """
  ¿Candidato universal? Margen neto con las comisiones más bajas posibles (sales tax con
  Accounting V y el broker mínimo, o el de la estructura si lo tiene) al menos
  `:screen_margin`.
  """
  @spec candidate?(float(), float(), float() | nil) :: boolean()
  def candidate?(best_bid, best_ask, broker_override \\ nil) do
    fees = %{tax: Fees.min_sales_tax(), broker: broker_override || GameRules.get(:min_broker_fee)}

    case price(best_bid, best_ask, fees) do
      nil -> false
      q -> q.margin_pct >= GameRules.get(:station_trading).screen_margin
    end
  end

  @doc """
  Cotización con las comisiones del piloto (`%{tax, broker}`) sobre el libro
  `%{bids, asks}` (órdenes `{precio, volumen, order_id, …}` del mejor al peor), sin las
  órdenes de `own_ids`. `nil` si falta un lado o no hay margen.
  """
  @spec quote(
          %{required(:bids) => list(), required(:asks) => list(), optional(atom()) => any()},
          %{tax: float(), broker: float()},
          MapSet.t()
        ) :: quote_t() | nil
  def quote(%{bids: bids, asks: asks}, fees, own_ids \\ MapSet.new()) do
    bids = Enum.reject(bids, &MapSet.member?(own_ids, elem(&1, 2)))
    asks = Enum.reject(asks, &MapSet.member?(own_ids, elem(&1, 2)))

    with [{best_bid, _, _, _, _} | _] <- bids,
         [{best_ask, _, _, _, _} | _] <- asks,
         %{} = q <- price(best_bid, best_ask, fees),
         true <- q.unit_margin > 0 do
      band = GameRules.get(:station_trading).competition_band

      Map.put(q, :competition, %{
        bids: Enum.count(bids, fn {p, _, _, _, _} -> p >= q.buy_price * (1 - band) end),
        asks: Enum.count(asks, fn {p, _, _, _, _} -> p <= q.sell_price * (1 + band) end)
      })
    else
      _ -> nil
    end
  end

  @doc """
  Plan diario: cantidad objetivo (participación del volumen de 7 días, acotada por el
  capital) y beneficio estimado por día. `capital` `nil` = sin límite.
  """
  @spec plan(quote_t(), number() | nil, number() | nil) :: %{
          quantity: non_neg_integer(),
          cost: float(),
          profit_day: float()
        }
  def plan(q, daily_volume, capital) do
    by_volume = floor((daily_volume || 0) * GameRules.get(:station_trading).participation)

    by_capital =
      if capital, do: floor(capital / OrderRules.escrow(q.unit_cost)), else: by_volume

    quantity = max(min(by_volume, by_capital), 0)

    %{
      quantity: quantity,
      cost: quantity * q.unit_cost,
      profit_day: quantity * q.unit_margin
    }
  end

  @doc """
  ¿Los precios sugeridos son realistas frente a lo que de verdad se opera? Ambos deben
  caer dentro de `:max_price_to_median` veces la mediana de 7 días (30 si en 7 hubo
  pocos días operados) hacia arriba y hacia abajo. Descarta, por ejemplo, una venta
  publicada a un precio absurdo que nadie va a pagar (el margen sería ilusorio). Sin
  mediana no hay forma de saberlo: `false`.
  """
  @spec realistic?(quote_t(), map() | nil) :: boolean()
  def realistic?(q, stats) do
    median = stats && (stats[:median_7d] || stats[:median_30d])
    ratio = GameRules.get(:station_trading).max_price_to_median

    is_number(median) and median > 0 and q.sell_price <= median * ratio and
      q.buy_price >= median / ratio
  end

  @doc "Certeza por competencia: 1 sin competidores, 0,5 con `:competition_half` en la banda."
  @spec competition_certainty(%{bids: non_neg_integer(), asks: non_neg_integer()}) :: float()
  def competition_certainty(%{bids: bids, asks: asks}) do
    half = GameRules.get(:station_trading).competition_half
    # El lado más disputado manda: hay que ganar las dos órdenes.
    half / (half + max(bids, asks))
  end

  defp price(best_bid, best_ask, fees) do
    with buy when is_float(buy) <- OrderRules.outbid(best_bid),
         sell when is_float(sell) <- OrderRules.undercut(best_ask),
         true <- buy < sell do
      unit_cost = buy * (1 + fees.broker)
      unit_revenue = sell * (1 - fees.tax - fees.broker)
      unit_margin = unit_revenue - unit_cost

      %{
        best_bid: best_bid / 1,
        best_ask: best_ask / 1,
        buy_price: buy,
        sell_price: sell,
        unit_cost: unit_cost,
        unit_revenue: unit_revenue,
        unit_margin: unit_margin,
        margin_pct: unit_margin / unit_cost
      }
    else
      _ -> nil
    end
  end
end
