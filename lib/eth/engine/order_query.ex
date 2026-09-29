defmodule Eth.Engine.OrderQuery do
  @moduledoc """
  Personalización de la familia **por órdenes** entre estaciones (RF-4.1, RF-4.14).

  Con las comisiones del piloto en el hub (sales tax por Accounting; broker por Broker
  Relations y standings) y sin sus propias órdenes:

  - **Listado:** precio de lista = el legal que supera a la mejor venta del hub. Se
    compra en el origen mientras cada unidad deje margen contra el ingreso neto de lista.
  - **Compra por orden:** precio de compra = el legal que supera a la mejor compra del
    hub. Se vende a las compras del destino mientras dejen margen contra el costo.

  La cantidad se acota por capital (el escrow de una compra es el 100 %), bodega y lo que
  el mercado del hub absorbe en `:max_days` días con la participación de
  `:station_trading` (volumen de 7 días del historial: sin historial no se propone). El
  tiempo estimado de ejecución es `cantidad / (participación × volumen diario)`.

  **Certeza** = frescura × anti-scam × competencia (órdenes cerca del precio sugerido).
  El orden por defecto es el beneficio ponderado por la Certeza y repartido en los días
  de espera (`score`).

  Implementa: RF-4.1, RF-4.14.
  """

  alias Eth.Engine.{
    Fees,
    OrderOpportunity,
    OrderRules,
    Query,
    Score,
    Shield,
    StationQuery,
    StationTrading
  }

  alias Eth.{GameRules, Routing}
  alias Eth.Market.{History, Prices}

  @sorts [:score, :profit, :margin, :days, :jumps]

  @type params :: %{optional(atom()) => any()}

  @doc "Ordenamientos válidos."
  @spec sorts() :: [atom()]
  def sorts, do: @sorts

  @doc "Parámetros por defecto (modo invitado)."
  @spec defaults() :: map()
  def defaults do
    rules = GameRules.get(:order_trading)

    StationQuery.defaults()
    |> Map.merge(%{
      mode: nil,
      cargo_m3: GameRules.get(:guest_cargo_m3),
      route_mode: :secure,
      base_system_id: GameRules.get(:route_root_system_id),
      ship_class: GameRules.get(:guest_ship_class),
      min_margin: rules.min_margin,
      min_profit: GameRules.get(:min_profit_isk),
      max_days: rules.max_days,
      sort: :score
    })
  end

  @doc "Devuelve `{filas, total}` como `Eth.Engine.Query.run/3`."
  @spec run([OrderOpportunity.t()], params(), DateTime.t()) :: {[map()], non_neg_integer()}
  def run(opportunities, params, now) do
    p = prepare(Map.merge(defaults(), params))
    search = Query.normalize(p.search)

    rows =
      opportunities
      |> Stream.filter(&(is_nil(p.mode) or &1.mode == p.mode))
      |> Stream.filter(&matches?(&1, search))
      |> Stream.map(&build(&1, p, now))
      |> Enum.filter(&(&1 && keep?(&1, p)))

    {rows |> sort(p.sort) |> Enum.take(p.limit), length(rows)}
  end

  @doc "Personaliza un candidato (`nil` si no es viable con estos parámetros)."
  @spec personalize(OrderOpportunity.t(), map(), DateTime.t()) :: map() | nil
  def personalize(%OrderOpportunity{} = opp, p, now),
    do: build(opp, prepare(Map.merge(defaults(), p)), now)

  @doc """
  Cota universal (RF-4.13): ¿el candidato puede llegar a `:min_profit_isk` en el mejor
  caso? Con las comisiones más bajas posibles, sin tope de capital ni de bodega y con
  lo que absorbe el mercado del hub. Lo usa el motor para no guardar candidatos que
  ningún piloto podría aprovechar.
  """
  @spec viable_upper_bound?(OrderOpportunity.t()) :: boolean()
  def viable_upper_bound?(%OrderOpportunity{} = opp) do
    hub = if opp.mode == :listing, do: opp.destination, else: opp.origin
    p = prepare(Map.merge(defaults(), %{capital: nil, cargo_m3: nil}))
    fees = %{tax: Fees.min_sales_tax(), broker: GameRules.get(:min_broker_fee)}

    with %{volume_avg_7d: daily} = stats when daily > 0 <-
           History.stats(hub.region_id, opp.type_id),
         %{} = result <- trade(opp, fees, daily, p) do
      result.profit >= GameRules.get(:min_profit_isk) and
        realistic?(result.price, stats, p.rules.ratio)
    else
      _ -> false
    end
  end

  # Lo que no depende del candidato se calcula una vez por consulta: reglas, modo de ruta
  # y comisiones de cada hub (RNF-1.1).
  defp prepare(p) do
    Map.merge(p, %{
      rules: %{
        participation: GameRules.get(:station_trading).participation,
        band: GameRules.get(:station_trading).competition_band,
        ratio: GameRules.get(:station_trading).max_price_to_median,
        min_unit_margin: GameRules.get(:min_unit_margin_isk)
      },
      mode_route: route_mode(p.route_mode),
      hub_fees:
        Map.new(GameRules.get(:station_trading_location_ids), &{&1, StationQuery.fees(&1, p)})
    })
  end

  defp build(opp, p, now) do
    hub = if opp.mode == :listing, do: opp.destination, else: opp.origin
    hub_stats = History.stats(hub.region_id, opp.type_id)
    age_min = DateTime.diff(now, opp.last_modified, :second) / 60

    mode = p.mode_route

    with %{volume_avg_7d: daily} when daily > 0 <- hub_stats,
         to_origin when is_integer(to_origin) <-
           Routing.distance(p.base_system_id, opp.origin.system_id, mode),
         jumps when is_integer(jumps) <-
           Routing.distance(opp.origin.system_id, opp.destination.system_id, mode),
         data_certainty when data_certainty > 0 <- Score.data_certainty(age_min),
         fees =
           Map.get_lazy(p.hub_fees, opp.hub_location_id, fn ->
             StationQuery.fees(opp.hub_location_id, p)
           end),
         %{} = result <- trade(opp, fees, daily, p),
         true <- realistic?(result.price, hub_stats, p.rules.ratio) do
      finish(opp, result, %{
        fees: fees,
        hub_stats: hub_stats,
        daily: daily,
        jumps_to_origin: to_origin,
        jumps: jumps,
        data_certainty: data_certainty,
        age_min: age_min,
        p: p,
        now: now
      })
    else
      _ -> nil
    end
  end

  defp finish(opp, result, ctx) do
    %{fees: fees, hub_stats: hub_stats, daily: daily, p: p} = ctx
    %{jumps_to_origin: jumps_to_origin, jumps: jumps, data_certainty: data_certainty} = ctx
    participation = p.rules.participation
    seconds = Score.travel_seconds(jumps_to_origin + jumps, 2, p.ship_class)
    days = result.quantity / (daily * participation)
    shield = shield(opp, result, hub_stats, ctx.now)
    scam_certainty = Shield.certainty(shield.status)

    competition_certainty =
      StationTrading.competition_certainty(%{bids: result.competition, asks: 0})

    certainty = data_certainty * scam_certainty * competition_certainty
    roi = result.profit / result.cost

    %{
      opportunity: opp,
      id: opp.id,
      mode: opp.mode,
      price: result.price,
      best_competitor: result.best_competitor,
      quantity: result.quantity,
      cost: result.cost,
      revenue: result.revenue,
      profit: result.profit,
      margin_pct: roi,
      roi: roi,
      days: days,
      daily_volume: daily,
      cargo_m3: result.quantity * opp.unit_volume,
      jumps_to_origin: jumps_to_origin,
      jumps: jumps,
      total_jumps: jumps_to_origin + jumps,
      seconds: seconds,
      tax_rate: fees.tax,
      broker_rate: fees.broker,
      competition: result.competition,
      used: result.used,
      certainty: certainty,
      score: result.profit * certainty / max(days, 1.0),
      shield: shield,
      history: hub_stats,
      age_min: ctx.age_min,
      breakdown: %{
        data_certainty: data_certainty,
        scam_certainty: scam_certainty,
        competition_certainty: competition_certainty
      }
    }
  end

  # Cantidad máxima que el hub absorbe en `max_days` días.
  defp market_cap(daily, p), do: floor(daily * p.rules.participation * p.max_days)

  ## Listado: compra en el origen, orden de venta en el hub.

  defp trade(%{mode: :listing} = opp, fees, daily, p) do
    competitors = Enum.reject(opp.sell_book, &MapSet.member?(p.own_order_ids, elem(&1, 2)))

    with [{best, _, _, _, _} | _] <- competitors,
         list_price when is_float(list_price) <- OrderRules.undercut(best) do
      net = list_price * (1 - fees.tax - fees.broker)
      caps = caps(opp, p, daily)

      {quantity, cost, used} =
        walk(opp.buy_book, caps, fn {price, _, _, _, _} -> net - price end, fn price -> price end)

      if quantity > 0 do
        %{
          price: list_price,
          best_competitor: best,
          quantity: quantity,
          cost: cost,
          revenue: quantity * net,
          profit: quantity * net - cost,
          competition: competition(competitors, list_price, :sell, p.rules.band),
          used: used
        }
      end
    else
      _ -> nil
    end
  end

  ## Compra por orden: orden de compra en el hub, venta a compras del destino.

  defp trade(%{mode: :buy_order} = opp, fees, daily, p) do
    competitors = Enum.reject(opp.buy_book, &MapSet.member?(p.own_order_ids, elem(&1, 2)))

    case competitors do
      [] -> nil
      [{best, _, _, _, _} | _] -> buy_order_trade(opp, fees, daily, p, competitors, best)
    end
  end

  defp buy_order_trade(opp, fees, daily, p, competitors, best) do
    buy_price = OrderRules.outbid(best)
    unit_cost = buy_price * (1 + fees.broker)
    caps = caps(opp, p, daily, unit_cost)

    {quantity, revenue, used} =
      walk(
        opp.sell_book,
        caps,
        fn {price, _, _, _, _} -> price * (1 - fees.tax) - unit_cost end,
        fn price -> price * (1 - fees.tax) end
      )

    if quantity > 0 do
      cost = quantity * unit_cost

      %{
        price: buy_price,
        best_competitor: best,
        quantity: quantity,
        cost: cost,
        revenue: revenue,
        profit: revenue - cost,
        competition: competition(competitors, buy_price, :buy, p.rules.band),
        used: used
      }
    end
  end

  # Topes de cantidad: capital, bodega y mercado del hub. En la compra por orden el
  # capital se mide al costo unitario de la orden propia (escrow 100 %).
  defp caps(opp, p, daily, unit_cost \\ nil) do
    %{
      min_unit_margin: p.rules.min_unit_margin,
      market: market_cap(daily, p),
      cargo: if(p.cargo_m3 && opp.unit_volume > 0, do: floor(p.cargo_m3 / opp.unit_volume)),
      capital: p.capital,
      unit_cost: unit_cost && OrderRules.escrow(unit_cost)
    }
  end

  # Recorre un libro del mejor al peor mientras cada unidad deje margen (`unit_margin`),
  # acumulando `amount` (costo en el Listado, ingreso en la compra por orden) hasta los
  # topes. Respeta `min_volume` de las órdenes de compra.
  defp walk(book, caps, unit_margin, amount) do
    min_margin = caps.min_unit_margin
    limit = Enum.min(Enum.reject([caps.market, caps.cargo], &is_nil/1))

    Enum.reduce_while(book, {0, 0.0, []}, fn {price, volume, _id, _issued, min_volume} = entry,
                                             {qty, total, used} ->
      room = min(volume, limit - qty) |> capital_room(caps, qty, total, price)

      cond do
        unit_margin.(entry) < min_margin or room <= 0 -> {:halt, {qty, total, used}}
        room < min_volume -> {:cont, {qty, total, used}}
        true -> {:cont, {qty + room, total + room * amount.(price), [{price, room} | used]}}
      end
    end)
    |> then(fn {qty, total, used} -> {qty, total, Enum.reverse(used)} end)
  end

  defp capital_room(room, %{capital: nil}, _qty, _total, _price), do: room

  # Compra por orden: capital fijo por unidad (el de la orden propia).
  defp capital_room(room, %{capital: capital, unit_cost: unit_cost}, qty, _total, _price)
       when is_number(unit_cost),
       do: min(room, floor(capital / unit_cost) - qty)

  # Listado: el capital se gasta al precio de cada orden de venta del origen.
  defp capital_room(room, %{capital: capital}, _qty, total, price),
    do: min(room, floor((capital - total) / price))

  defp competition(orders, price, side, band) do
    Enum.count(orders, fn {p, _, _, _, _} ->
      if side == :sell, do: p <= price * (1 + band), else: p >= price * (1 - band)
    end)
  end

  defp realistic?(price, stats, ratio) do
    median = stats[:median_7d] || stats[:median_30d]
    is_number(median) and median > 0 and price <= median * ratio and price >= median / ratio
  end

  defp shield(opp, result, hub_stats, now) do
    {bid, ask, dest_stats, origin_stats} =
      case opp.mode do
        :listing ->
          {result.price, result.used |> Enum.map(&elem(&1, 0)) |> Enum.min(), hub_stats,
           History.stats(opp.origin.region_id, opp.type_id)}

        :buy_order ->
          {result.used |> Enum.map(&elem(&1, 0)) |> Enum.max(), result.price,
           History.stats(opp.destination.region_id, opp.type_id), hub_stats}
      end

    Shield.evaluate(%{
      bid: bid,
      ask: ask,
      roi: result.profit / result.cost,
      bid_min_volume: 1,
      bid_issued: nil,
      dest_stats: dest_stats,
      origin_stats: origin_stats,
      global_average: Prices.average(opp.type_id),
      now: now
    })
  end

  # El modo Evasiva usa el radar (familia directo); aquí basta con la Segura.
  defp route_mode(:evasive), do: :secure
  defp route_mode(mode), do: mode

  defp keep?(row, p) do
    row.margin_pct >= p.min_margin and row.profit >= p.min_profit and
      Query.shield_visible?(row.shield.status, p.shield)
  end

  defp matches?(_opp, ""), do: true

  defp matches?(opp, search) do
    [
      opp.type_name,
      opp.origin.name,
      opp.origin.system_name,
      opp.destination.name,
      opp.destination.system_name
    ]
    |> Enum.any?(&(&1 && String.contains?(Query.normalize(&1), search)))
  end

  defp sort(rows, :profit), do: Enum.sort_by(rows, &{-&1.profit, -&1.score})
  defp sort(rows, :margin), do: Enum.sort_by(rows, &{-&1.margin_pct, -&1.score})
  defp sort(rows, :days), do: Enum.sort_by(rows, &{&1.days, -&1.score})
  defp sort(rows, :jumps), do: Enum.sort_by(rows, &{&1.total_jumps, -&1.score})
  defp sort(rows, _score), do: Enum.sort_by(rows, &{-&1.score, -&1.profit})
end
