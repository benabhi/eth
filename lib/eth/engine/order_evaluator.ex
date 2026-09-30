defmodule Eth.Engine.OrderEvaluator do
  @moduledoc """
  Cruce universal de la familia **por órdenes** entre estaciones (RF-4.1) con los hubs de
  `:station_trading_location_ids` como estación donde se publica la orden propia.

  Por tipo (en paralelo), con los resúmenes de todas las fuentes:

  - **Listado:** en cada hub con órdenes de venta, el precio de lista es el legal que
    supera a la mejor (`OrderRules.undercut/1`). Son orígenes las ubicaciones cuya mejor
    venta deja al menos `:screen_margin` de margen neto con las comisiones más bajas
    posibles (hasta `:max_origins`, las más baratas, alcanzables por ruta).
  - **Compra por orden:** en cada hub con órdenes de compra, el precio de la orden
    propia supera a la mejor (`OrderRules.outbid/1`). Son destinos las ubicaciones cuya
    mejor compra deja ese margen al vender (hasta `:max_destinations`), con las compras
    que cubren la estación por rango (RF-4.3).

  Ambas puntas son estaciones NPC (el acceso a estructuras, AS-8, queda para después).

  Solo se arman (leyendo los libros de ETS) los candidatos cuyo hub tiene historial; de
  los demás se devuelve el par `(región, tipo)` para pedirlo (entran en la evaluación
  siguiente). Y solo se guardan los que llegan al beneficio mínimo en el mejor caso
  (`Eth.Engine.OrderQuery.viable_upper_bound?/1`). La cantidad, el tiempo de ejecución
  y el beneficio personales se calculan en la consulta.

  Implementa: RF-4.1.
  """

  alias Eth.Engine.{
    Evaluator,
    Fees,
    Locations,
    OrderOpportunity,
    OrderQuery,
    OrderRules,
    PublishLocations,
    Range
  }

  alias Eth.{GameRules, Routing, Sde}
  alias Eth.Market.{History, OrderBook}

  @doc """
  Evalúa todos los tipos con las fuentes del motor. Devuelve los candidatos viables y los
  pares `(región, tipo)` de hubs sin historial.
  """
  @spec run([map()], Enumerable.t(), [PublishLocations.location()]) :: %{
          candidates: [OrderOpportunity.t()],
          missing_history: [{pos_integer(), pos_integer()}]
        }
  def run(sources, types, locations \\ PublishLocations.list()) do
    ctx = context(sources, locations)

    results =
      if ctx.hubs == [] do
        []
      else
        types
        |> Task.async_stream(&evaluate_type(&1, ctx),
          max_concurrency: System.schedulers_online(),
          ordered: false,
          timeout: :infinity
        )
        |> Enum.flat_map(fn {:ok, results} -> results end)
      end

    %{
      candidates: for({:ok, opp} <- results, do: opp),
      missing_history: results |> Enum.flat_map(&missing/1) |> Enum.uniq()
    }
  end

  defp missing({:missing, pair}), do: [pair]
  defp missing(_ok), do: []

  @doc false
  @spec context([map()], [PublishLocations.location()]) :: map()
  def context(sources, locations \\ PublishLocations.hubs()) do
    rules = GameRules.get(:order_trading)
    by_source = Map.new(sources, &{&1.source, &1})
    has_source? = &Map.has_key?(by_source, &1)

    hubs =
      for place <- locations,
          %{} = src <- [Map.get(by_source, PublishLocations.source(place, has_source?))],
          do: Map.put(place, :src, src)

    %{
      sources: sources,
      direct: for(%{source: {:structure, id}} <- sources, into: MapSet.new(), do: id),
      hubs: hubs,
      rules: rules,
      tax: Fees.min_sales_tax(),
      broker: GameRules.get(:min_broker_fee)
    }
  end

  @doc false
  @spec evaluate_type(pos_integer(), map()) :: [
          {:ok, OrderOpportunity.t()} | {:missing, {pos_integer(), pos_integer()}}
        ]
  def evaluate_type(type_id, ctx) do
    with %{} = type <- Sde.type(type_id),
         {asks, bids} when asks != [] or bids != [] <- Evaluator.gather(type_id, ctx) do
      Enum.flat_map(ctx.hubs, fn hub ->
        pending = listing(hub, asks, type_id, ctx) ++ buy_order(hub, bids, type_id, ctx)
        finish(pending, hub, type_id, type)
      end)
    else
      _ -> []
    end
  end

  # Candidatos del screening de un hub: sin historial, solo el pedido; con historial, se
  # leen los libros y se aplica la cota universal.
  defp finish([], _hub, _type_id, _type), do: []

  defp finish(pending, hub, type_id, type) do
    if History.stats(hub.region_id, type_id) do
      pending
      |> Enum.map(fn builder -> builder.(type) end)
      |> Enum.filter(&OrderQuery.viable_upper_bound?/1)
      |> Enum.map(&{:ok, &1})
    else
      [{:missing, {hub.region_id, type_id}}]
    end
  end

  ## Listado

  defp listing(hub, asks, type_id, ctx) do
    with %{price: hub_ask} <- Enum.find(asks, &(&1.location_id == hub.location_id)),
         list_price when is_float(list_price) <- OrderRules.undercut(hub_ask) do
      net = list_price * (1 - ctx.tax - screen_broker(hub, ctx))

      asks
      |> Enum.reject(&(&1.location_id == hub.location_id))
      |> Enum.filter(&(npc_station?(&1) and &1.price * (1 + ctx.rules.screen_margin) <= net))
      |> Enum.sort_by(& &1.price)
      |> Enum.take(ctx.rules.max_origins)
      |> Enum.flat_map(&listing_candidate(&1, hub, type_id, ctx))
    else
      _ -> []
    end
  end

  defp listing_candidate(origin, hub, type_id, ctx) do
    case Routing.distance(origin.system_id, hub.system_id, :shortest) do
      nil ->
        []

      jumps ->
        [
          fn type ->
            build(:listing, origin, hub, jumps, type_id, type,
              buy_book: book(origin.src, type_id, :sell, origin.location_id, ctx),
              sell_book: book(hub.src, type_id, :sell, hub.location_id, ctx)
            )
          end
        ]
    end
  end

  ## Compra por orden

  defp buy_order(hub, bids, type_id, ctx) do
    case Enum.filter(bids, &(&1.location_id == hub.location_id)) do
      [] ->
        []

      hub_bids ->
        best = Enum.max_by(hub_bids, & &1.price)
        cost = OrderRules.outbid(best.price) * (1 + screen_broker(hub, ctx))
        floor = cost * (1 + ctx.rules.screen_margin)

        bids
        |> Enum.reject(&(&1.location_id == hub.location_id))
        |> Enum.filter(&(npc_station?(&1) and &1.price * (1 - ctx.tax) >= floor))
        |> Enum.sort_by(& &1.price, :desc)
        |> Enum.uniq_by(& &1.location_id)
        |> Enum.take(ctx.rules.max_destinations)
        |> Enum.flat_map(&buy_order_candidate(&1, hub, bids, type_id, ctx))
    end
  end

  defp buy_order_candidate(dest, hub, bids, type_id, ctx) do
    target = Map.take(dest, [:location_id, :system_id, :region_id])
    jumps_fun = &Routing.distance(&1, &2, :shortest)

    with jumps when is_integer(jumps) <-
           Routing.distance(hub.system_id, dest.system_id, :shortest),
         [_ | _] = eligible <- Enum.filter(bids, &Range.covers?(&1, target, jumps_fun)) do
      sell_book =
        eligible
        |> Enum.sort_by(& &1.price, :desc)
        |> Enum.take(ctx.rules.book_depth)
        |> Enum.map(&{&1.price, &1.volume, 0, &1.issued, &1.min_volume})

      [
        fn type ->
          build(:buy_order, hub, dest, jumps, type_id, type,
            buy_book: book(hub.src, type_id, :buy, hub.location_id, ctx),
            sell_book: sell_book
          )
        end
      ]
    else
      _ -> []
    end
  end

  ## Común

  # Broker más bajo posible en el lugar de la orden propia: el de la estructura si lo
  # tiene (puede ser menor que el mínimo NPC), si no el mínimo NPC.
  defp screen_broker(%{broker_override: broker}, _ctx) when is_number(broker), do: broker
  defp screen_broker(_hub, ctx), do: ctx.broker

  # Por ahora la familia por órdenes solo usa estaciones NPC en las dos puntas: el acceso a
  # estructuras por personaje (AS-8) todavía no entra en su Certeza.
  defp npc_station?(%{location_id: id}), do: Sde.station(id) != nil

  defp build(mode, origin, destination, jumps, type_id, type, books) do
    %OrderOpportunity{
      id: OrderOpportunity.id(mode, type_id, origin.location_id, destination.location_id),
      mode: mode,
      type_id: type_id,
      type_name: type.name,
      unit_volume: type.packaged_volume,
      origin: Locations.describe(origin.location_id, origin.system_id),
      destination: Locations.describe(destination.location_id, destination.system_id),
      hub_location_id:
        if(mode == :listing, do: destination.location_id, else: origin.location_id),
      hub_broker_override:
        Map.get(if(mode == :listing, do: destination, else: origin), :broker_override),
      jumps: jumps,
      secure_jumps: Routing.distance(origin.system_id, destination.system_id, :secure),
      last_modified:
        Enum.min([origin.src.last_modified, destination.src.last_modified], DateTime),
      buy_book: books[:buy_book],
      sell_book: books[:sell_book]
    }
  end

  defp book(src, type_id, side, location_id, ctx) do
    OrderBook.at_location(src.tid, type_id, side, location_id, ctx.rules.book_depth)
  rescue
    # La generación pudo borrarse tras el período de gracia durante una evaluación larga.
    ArgumentError -> []
  end
end
