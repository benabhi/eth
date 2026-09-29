defmodule Eth.Engine.Evaluator do
  @moduledoc """
  Cruce universal del arbitraje instantáneo (RF-4.2 a RF-4.4).

  Para cada tipo presente en alguna fuente (en paralelo):

  1. **Screening:** reúne de los resúmenes las mejores ventas por ubicación y todas las
     órdenes de compra. Una ubicación de compra es candidata si su mejor precio deja
     margen contra la mejor compra con el impuesto mínimo posible.
  2. **Estaciones de venta:** la ubicación de cada orden de compra candidata y, si alguna
     orden con rango cubre el origen, el propio origen ("venta en el lugar").
  3. **Walk-the-book:** con el libro completo de ventas del origen y las compras que cubren
     cada estación de venta (RF-4.3), con el impuesto del modo invitado.
  4. Descarta duplicados (mismas órdenes de compra consumidas desde otra estación) y
     conserva las más cercanas.

  Límites para acotar el trabajo: `@max_origins` orígenes por tipo y `@max_sell_locations`
  estaciones de venta por origen.

  Implementa: RF-4.2, RF-4.3, RF-4.4, RF-4.9.
  """

  alias Eth.Engine.{Book, Fees, Locations, Opportunity, Range, Summary}
  alias Eth.{GameRules, Routing, Sde}

  @max_origins 8
  @max_sell_locations 6

  @type source :: %{
          source: term(),
          tid: :ets.tid(),
          region_id: pos_integer(),
          last_modified: DateTime.t()
        }

  @doc """
  Evalúa todos los tipos. `types` es el conjunto de tipos a evaluar; `opts`: `:tax`
  (sales tax del modo invitado) y `:min_profit`.
  """
  @spec run([source()], Enumerable.t(), keyword()) :: [Opportunity.t()]
  def run(sources, types, opts) do
    ctx = %{
      sources: sources,
      tax: Keyword.fetch!(opts, :tax),
      screen_tax: Fees.min_sales_tax(),
      min_profit: Keyword.fetch!(opts, :min_profit),
      min_margin: GameRules.get(:min_unit_margin_isk)
    }

    types
    |> Task.async_stream(&evaluate_type(&1, ctx),
      max_concurrency: System.schedulers_online(),
      ordered: false,
      timeout: :infinity
    )
    |> Enum.flat_map(fn {:ok, opportunities} -> opportunities end)
  end

  @doc false
  @spec evaluate_type(pos_integer(), map()) :: [Opportunity.t()]
  def evaluate_type(type_id, ctx) do
    with %{} = type <- Sde.type(type_id),
         {asks, bids} when asks != [] and bids != [] <- gather(type_id, ctx.sources) do
      best_bid = bids |> Enum.map(& &1.price) |> Enum.max()
      screen_net = best_bid * (1 - ctx.screen_tax)

      asks
      |> Enum.filter(&(screen_net - &1.price >= ctx.min_margin))
      |> Enum.sort_by(& &1.price)
      |> Enum.take(@max_origins)
      |> Enum.flat_map(&evaluate_origin(&1, bids, type_id, type, ctx))
    else
      _ -> []
    end
  end

  # Mejores ventas por ubicación y compras de todas las fuentes, con su región y fuente.
  defp gather(type_id, sources) do
    Enum.reduce(sources, {[], []}, fn src, {asks, bids} ->
      {src_asks, src_bids} = Summary.get(src.source, type_id)

      asks =
        Enum.reduce(src_asks, asks, fn {price, loc, sys}, acc ->
          [
            %{price: price, location_id: loc, system_id: sys, region_id: src.region_id, src: src}
            | acc
          ]
        end)

      bids =
        Enum.reduce(src_bids, bids, fn {price, loc, sys, range, vol, min_vol, issued}, acc ->
          [
            %{
              price: price,
              location_id: loc,
              system_id: sys,
              region_id: src.region_id,
              range: range,
              volume: vol,
              min_volume: min_vol,
              issued: issued,
              src: src
            }
            | acc
          ]
        end)

      {asks, bids}
    end)
  end

  defp evaluate_origin(origin, bids, type_id, type, ctx) do
    candidates =
      Enum.filter(bids, &(&1.price * (1 - ctx.screen_tax) - origin.price >= ctx.min_margin))

    if candidates == [] do
      []
    else
      ask_book = ask_book(origin, type_id)

      origin
      |> sell_locations(candidates)
      |> Enum.flat_map(&evaluate_sale(origin, &1, candidates, ask_book, type_id, type, ctx))
      |> dedupe()
    end
  end

  # Estaciones de venta: donde está cada orden candidata y el origen si alguna lo cubre.
  defp sell_locations(origin, candidates) do
    own =
      candidates
      |> Enum.sort_by(& &1.price, :desc)
      |> Enum.map(&Map.take(&1, [:location_id, :system_id, :region_id]))

    in_place =
      if Enum.any?(candidates, &Range.covers?(&1, origin, jumps_fun())),
        do: [Map.take(origin, [:location_id, :system_id, :region_id])],
        else: []

    (in_place ++ own) |> Enum.uniq_by(& &1.location_id) |> Enum.take(@max_sell_locations)
  end

  defp evaluate_sale(origin, sell, candidates, ask_book, type_id, type, ctx) do
    eligible = Enum.filter(candidates, &Range.covers?(&1, sell, jumps_fun()))
    jumps = Routing.distance(origin.system_id, sell.system_id, :shortest)

    with true <- eligible != [] and jumps != nil,
         result = walk(ask_book, eligible, type, ctx),
         true <- result.quantity > 0 and result.profit >= ctx.min_profit do
      [build(origin, sell, eligible, result, jumps, type_id, type)]
    else
      _ -> []
    end
  end

  defp walk(ask_book, eligible, type, ctx) do
    bids = Enum.map(eligible, &{&1.price, &1.volume, &1.min_volume})

    Book.walk(ask_book, bids, ctx.tax, %{
      unit_volume: type.packaged_volume,
      min_unit_margin: ctx.min_margin
    })
  end

  # Libro completo de ventas del tipo en la ubicación de origen.
  defp ask_book(origin, type_id) do
    loc = origin.location_id
    pattern = {{type_id, :sell, :"$1", :_}, loc, :_, :"$2", :_, :_, :_, :_, :_}

    :ets.select(origin.src.tid, [{pattern, [], [{{:"$1", :"$2"}}]}])
  rescue
    # La generación pudo borrarse tras el período de gracia durante una evaluación larga.
    ArgumentError -> []
  end

  defp build(origin, sell, eligible, result, jumps, type_id, type) do
    remote? = not Enum.any?(eligible, &(&1.location_id == sell.location_id))
    dest_src = eligible |> Enum.map(& &1.src.last_modified) |> Enum.min(DateTime)

    %Opportunity{
      id: Opportunity.id(type_id, origin.location_id, sell.location_id),
      type_id: type_id,
      type_name: type.name,
      unit_volume: type.packaged_volume,
      origin: Locations.describe(origin.location_id, origin.system_id),
      destination: Locations.describe(sell.location_id, sell.system_id),
      quantity: result.quantity,
      cost: result.cost,
      revenue: result.revenue,
      tax: result.tax,
      profit: result.profit,
      avg_buy: result.avg_buy,
      avg_sell: result.avg_sell,
      jumps: jumps,
      secure_jumps: Routing.distance(origin.system_id, sell.system_id, :secure),
      last_modified: Enum.min([origin.src.last_modified, dest_src], DateTime),
      remote_sale: remote?,
      asks: result.asks_used,
      bids: result.bids_used,
      bid_issued: newest_issued(eligible, result.bids_used)
    }
  end

  # Creación de la orden de compra más reciente entre las que caen en el rango de precios
  # consumido (AS-6: una compra inflada suele ser recién creada).
  defp newest_issued(eligible, bids_used) do
    floor_price = bids_used |> Enum.map(&elem(&1, 0)) |> Enum.min()

    eligible
    |> Enum.filter(&(&1.price >= floor_price))
    |> Enum.map(& &1.issued)
    |> Enum.max()
    |> DateTime.from_unix!()
  end

  # Las mismas órdenes de compra alcanzadas desde varias estaciones: queda la más cercana.
  defp dedupe(opportunities) do
    opportunities
    |> Enum.sort_by(&{&1.jumps, -&1.profit})
    |> Enum.uniq_by(&{&1.bids, &1.quantity})
  end

  defp jumps_fun, do: &Routing.distance(&1, &2, :shortest)
end
