defmodule Eth.Engine do
  @moduledoc """
  API pública del motor de evaluación para la web y otros contextos (RNF-7.3).

  Implementa: RF-4.8, RF-4.12, RF-4.13, RF-4.14, RF-6.5, RF-6.14, RF-6.15, RF-6.16.
  """

  alias Eth.{Clock, Events, GameRules, Market, Repo}

  alias Eth.Engine.{
    BookDepth,
    Coordinator,
    Fees,
    FirstSeen,
    Locations,
    Opportunity,
    OrderOpportunity,
    OrderQuery,
    OwnOrders,
    PublishLocations,
    Query,
    Range,
    RouteRisk,
    SaleQuote,
    ScamReport,
    SkillGains,
    StationOpportunity,
    StationQuery,
    Summary
  }

  alias Eth.Market.{History, OrderBook, TableOwner}

  @doc "Tópico con los anuncios de nueva versión de oportunidades."
  @spec topic() :: String.t()
  defdelegate topic, to: Coordinator

  @doc "Metadatos de la evaluación vigente (versión, duración, conteos) o `nil`."
  @spec meta() :: map() | nil
  def meta do
    case Coordinator.current() do
      {_tid, meta} -> meta
      nil -> nil
    end
  end

  @doc "Oportunidades universales vigentes."
  @spec all() :: [Opportunity.t()]
  def all do
    case Coordinator.current() do
      {tid, _meta} -> tid |> :ets.tab2list() |> Enum.map(&elem(&1, 1))
      nil -> []
    end
  rescue
    ArgumentError -> []
  end

  @doc "Oportunidad universal por ID."
  @spec get(String.t()) :: Opportunity.t() | nil
  def get(id) do
    case Coordinator.current() do
      {tid, _meta} ->
        case :ets.lookup(tid, id) do
          [{^id, opp}] -> opp
          [] -> nil
        end

      nil ->
        nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc """
  Registra un falso positivo del anti-scam (RF-4.8) a partir de una fila personalizada,
  con un comentario opcional.
  """
  @spec report_false_positive(map(), String.t() | nil) ::
          {:ok, ScamReport.t()} | {:error, Ecto.Changeset.t()}
  def report_false_positive(row, reason \\ nil) do
    %ScamReport{}
    |> ScamReport.changeset(%{opportunity_snapshot: ScamReport.snapshot(row), reason: reason})
    |> Repo.insert()
    |> tap(fn
      {:ok, _report} ->
        Events.emit(
          :action,
          "Usuario",
          "Falso positivo reportado: #{row.opportunity.type_name} (#{row.shield.status})"
        )

      _error ->
        :ok
    end)
  end

  @doc """
  Detalle por sistema del camino de una fila personalizada (RF-6.5, sección Ruta): ida
  hasta el origen sin carga y viaje cargado hasta el destino.
  """
  @spec route_details(map(), atom()) :: %{to_origin: [map()], route: [map()]}
  def route_details(row, ship_class) do
    ctx = RouteRisk.context()

    %{
      to_origin: RouteRisk.details(row.to_origin_path, ship_class, 0, ctx),
      route: RouteRisk.details(row.route_path, ship_class, row.cost, ctx)
    }
  end

  @doc """
  Cotizaciones de venta de `quantity` unidades de un tipo con las órdenes de compra
  vigentes de todas las fuentes (RF-7.3), de mayor a menor ingreso neto.
  """
  @spec sale_quotes(pos_integer(), pos_integer(), float()) :: [SaleQuote.quote_result()]
  def sale_quotes(type_id, quantity, tax) do
    SaleQuote.best(bids(type_id), quantity, tax, &Eth.Routing.distance(&1, &2, :shortest))
  end

  @doc "Cotización de venta en una estación concreta (RF-7.3)."
  @spec sale_quote(pos_integer(), map(), pos_integer(), float()) :: SaleQuote.quote_result()
  def sale_quote(type_id, location, quantity, tax) do
    SaleQuote.at(location, bids(type_id), quantity, tax, &Eth.Routing.distance(&1, &2, :shortest))
  end

  # Órdenes de compra del tipo en todas las fuentes, sin las de estructuras que se leen
  # directo repetidas en la región (RF-1.6).
  defp bids(type_id) do
    entries = TableOwner.all()
    direct = for {{:structure, id}, _entry} <- entries, into: MapSet.new(), do: id

    for {source, entry} <- entries,
        region_id = region_of(source, entry),
        {price, loc, sys, range, vol, min_vol, _issued} <- elem(Summary.get(source, type_id), 1),
        not (match?({:region, _}, source) and MapSet.member?(direct, loc)) do
      %{
        price: price,
        location_id: loc,
        system_id: sys,
        region_id: region_id,
        range: range,
        volume: vol,
        min_volume: min_vol
      }
    end
  rescue
    ArgumentError -> []
  end

  defp region_of({:region, id}, _entry), do: id
  defp region_of({:structure, _id}, entry), do: entry.meta[:region_id]

  ## Ficha del contrato: antigüedad, habilidades y libro (RF-6.14 a RF-6.16)

  @doc """
  Minutos que lleva una oportunidad en el tablón y si es una cota inferior (ya estaba al
  arrancar la aplicación). `nil` si no se conoce. Ver `Eth.Engine.FirstSeen`.
  """
  @spec board_age(map(), map() | nil, DateTime.t()) :: {non_neg_integer(), boolean()} | nil
  def board_age(opp, meta, now),
    do: FirstSeen.age(Map.get(opp, :first_seen), meta && meta[:seen_since], now)

  @doc """
  Cuánto ganaría el piloto subiendo sus habilidades de comercio en este contrato
  (`Eth.Engine.SkillGains`): Accounting en las tres familias y Broker Relations en las que
  publican órdenes. `params` son los de la consulta de la familia.
  """
  @spec skill_gains(:direct | :station | :orders, struct(), map()) :: [SkillGains.gain()]
  def skill_gains(family, opp, params) do
    now = Clock.utc_now()

    case family do
      :direct ->
        p = Map.merge(Query.defaults(), params)
        SkillGains.gains(p, [:accounting], &value(Query.personalize(opp, &1, now), :profit))

      :station ->
        p = Map.merge(StationQuery.defaults(), params)

        SkillGains.gains(
          p,
          [:accounting, :broker_relations],
          &value(StationQuery.personalize(opp, &1, now), :profit_day)
        )

      :orders ->
        p = Map.merge(OrderQuery.defaults(), params)

        SkillGains.gains(
          p,
          [:accounting, :broker_relations],
          &value(OrderQuery.personalize(opp, &1, now), :profit)
        )
    end
  end

  defp value(nil, _field), do: nil
  defp value(row, field), do: Map.fetch!(row, field)

  @book_depth_levels 5
  # Órdenes de venta del origen que se leen como máximo (el libro de un hub puede tener
  # cientos; las consumidas más las siguientes casi nunca pasan de unas decenas).
  @book_depth_scan 300

  @doc """
  Libro más allá de lo que consume un contrato directo (`Eth.Engine.BookDepth`): las
  siguientes ventas del origen y compras que cubren el destino, y el beneficio si la
  mejor compra desaparece antes de llegar (`nil` si deja de ser rentable). Lee las tablas
  de órdenes en memoria, sin consultar a ESI. `nil` si el libro ya no está.
  """
  @spec book_depth(map(), map()) ::
          %{asks: [BookDepth.level()], bids: [BookDepth.level()], fallback: map() | nil} | nil
  def book_depth(%{opportunity: opp} = row, params) do
    p = Map.merge(Query.defaults(), params)
    asks = origin_asks(opp)
    bids = destination_bids(opp)

    limits = %{
      capital: p.capital || :infinity,
      cargo_m3: p.cargo_m3 || :infinity,
      unit_volume: opp.unit_volume,
      min_unit_margin: GameRules.get(:min_unit_margin_isk)
    }

    %{
      asks: BookDepth.next_levels(asks, consumed(row.asks_used), @book_depth_levels),
      bids:
        BookDepth.next_levels(
          Enum.map(bids, fn {price, qty, _min} -> {price, qty} end),
          consumed(row.bids_used),
          @book_depth_levels
        ),
      fallback: BookDepth.without_best_bid(asks, bids, Fees.sales_tax(p.accounting), limits)
    }
  rescue
    # La generación pudo borrarse tras su período de gracia en plena lectura.
    ArgumentError -> nil
  end

  defp consumed(levels), do: Enum.sum_by(levels, &elem(&1, 1))

  # Ventas del origen, de menor a mayor precio: la estructura si se lee directo; si no, la
  # región.
  defp origin_asks(%{origin: origin, type_id: type_id}) do
    source =
      if TableOwner.current({:structure, origin.location_id}),
        do: {:structure, origin.location_id},
        else: {:region, origin.region_id}

    case TableOwner.current(source) do
      %{tid: tid} ->
        tid
        |> OrderBook.at_location(type_id, :sell, origin.location_id, @book_depth_scan)
        |> Enum.map(fn {price, qty, _id, _issued, _min} -> {price, qty} end)

      nil ->
        []
    end
  end

  # Compras de todas las fuentes cuyo rango cubre el destino, de mayor a menor precio.
  defp destination_bids(%{destination: destination, type_id: type_id}) do
    jumps = &Eth.Routing.distance(&1, &2, :shortest)

    type_id
    |> bids()
    |> Enum.filter(&Range.covers?(&1, destination, jumps))
    |> Enum.sort_by(& &1.price, :desc)
    |> Enum.map(&{&1.price, &1.volume, &1.min_volume})
  end

  @doc "Consulta personalizada (RF-4.14): `{filas, total}`."
  @spec query(Query.params()) :: {[map()], non_neg_integer()}
  def query(params \\ %{}) do
    started = System.monotonic_time(:microsecond)
    result = Query.run(all(), params, Clock.utc_now())

    :telemetry.execute(
      [:eth, :engine, :query],
      %{duration_us: System.monotonic_time(:microsecond) - started},
      %{rows: elem(result, 1)}
    )

    result
  end

  ## Station trading (RF-4.16)

  @doc "Candidatos universales de station trading vigentes."
  @spec station_all() :: [StationOpportunity.t()]
  def station_all do
    case Coordinator.current_station() do
      nil -> []
      tid -> tid |> :ets.tab2list() |> Enum.map(&elem(&1, 2))
    end
  rescue
    ArgumentError -> []
  end

  @doc "Candidato de station trading por ID."
  @spec station_get(String.t()) :: StationOpportunity.t() | nil
  def station_get(id) do
    case Coordinator.current_station() do
      nil ->
        nil

      tid ->
        case :ets.lookup(tid, id) do
          [{^id, _pair, opp}] -> opp
          [] -> nil
        end
    end
  rescue
    ArgumentError -> nil
  end

  @doc """
  Consulta personalizada de station trading: `{filas, total}`. Primero descarta, sin
  copiar los candidatos, los que no tienen historial suficiente (la gran mayoría).
  """
  @spec station_query(StationQuery.params()) :: {[map()], non_neg_integer()}
  def station_query(params \\ %{}) do
    now = Clock.utc_now()

    case Coordinator.current_station() do
      nil ->
        {[], 0}

      tid ->
        parallel_run(
          tid,
          StationQuery.liquid_pair_fun(params),
          &StationQuery.run(&1, params, now),
          &StationQuery.top(&1, params)
        )
    end
  rescue
    ArgumentError -> {[], 0}
  end

  # Consulta en paralelo sobre una tabla de candidatos `{id, {región, tipo}, candidato}`
  # (RNF-1.1): con el universo completo son decenas de miles y cada uno trae su libro de
  # órdenes, así que copiarlos al proceso de la vista costaba más que calcularlos. Cada
  # tarea lee su parte de ETS, filtra, personaliza y devuelve solo sus primeras filas y
  # el total; al final se combinan.
  defp parallel_run(tid, keep_pair?, run, top) do
    pairs = :ets.select(tid, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    workers = System.schedulers_online()

    if length(pairs) < GameRules.get(:engine_parallel_min) or workers == 1 do
      tid |> candidates(pairs, keep_pair?) |> run.()
    else
      results =
        pairs
        |> Enum.chunk_every(div(length(pairs), workers) + 1)
        |> Task.async_stream(&run_chunk(tid, &1, keep_pair?, run),
          max_concurrency: workers,
          timeout: :infinity
        )
        |> Enum.map(fn {:ok, result} -> result end)

      {results |> Enum.flat_map(&elem(&1, 0)) |> top.(), Enum.sum_by(results, &elem(&1, 1))}
    end
  end

  # La generación pudo borrarse tras su período de gracia en plena consulta: la tarea
  # devuelve vacío en lugar de tirar la vista.
  defp run_chunk(tid, pairs, keep_pair?, run) do
    tid |> candidates(pairs, keep_pair?) |> run.()
  rescue
    ArgumentError -> {[], 0}
  end

  defp candidates(tid, pairs, keep_pair?) do
    for {id, pair} <- pairs,
        keep_pair?.(pair),
        [{^id, _pair, opp}] <- [:ets.lookup(tid, id)],
        do: opp
  end

  @doc """
  Lugares donde se publican órdenes propias: los hubs NPC y las estructuras con broker
  propio (RF-9.4), como `[{id, nombre}]`.
  """
  @spec publish_locations() :: [{pos_integer(), String.t()}]
  def publish_locations do
    for place <- PublishLocations.list(),
        do: {place.location_id, Locations.describe(place.location_id, place.system_id).name}
  end

  ## Por órdenes entre estaciones (RF-4.1)

  @doc "Candidato de la familia por órdenes por ID."
  @spec order_get(String.t()) :: OrderOpportunity.t() | nil
  def order_get(id) do
    case Coordinator.current_orders() do
      nil ->
        nil

      tid ->
        case :ets.lookup(tid, id) do
          [{^id, _pair, opp}] -> opp
          [] -> nil
        end
    end
  rescue
    ArgumentError -> nil
  end

  @doc """
  Consulta personalizada de la familia por órdenes: `{filas, total}`. Descarta primero,
  sin copiar los candidatos, los que no tienen historial en el hub.
  """
  @spec order_query(map()) :: {[map()], non_neg_integer()}
  def order_query(params \\ %{}) do
    now = Clock.utc_now()

    case Coordinator.current_orders() do
      nil ->
        {[], 0}

      tid ->
        parallel_run(
          tid,
          &order_liquid?/1,
          &OrderQuery.run(&1, params, now),
          &OrderQuery.top(&1, params)
        )
    end
  rescue
    ArgumentError -> {[], 0}
  end

  defp order_liquid?({region_id, type_id}) do
    match?(%{volume_avg_7d: v} when v > 0, History.stats(region_id, type_id))
  end

  ## Órdenes propias (RF-4.17)

  @own_book_depth 20

  @doc """
  Estado de las órdenes propias frente al libro vigente de su ubicación: primera o
  superada, precio sugerido y costo de modificarla. `params` como en
  `Eth.Engine.StationQuery` (Accounting, Broker Relations y standings para el broker) más
  `:advanced_broker_relations` (relist) y `:own_order_ids` (todas las órdenes propias, que
  no compiten entre sí).
  """
  @spec own_orders([OwnOrders.order()], map()) :: [map()]
  def own_orders(orders, params) do
    p = Map.merge(StationQuery.defaults(), params)
    own_ids = Map.get(params, :own_order_ids) || MapSet.new(orders, & &1.order_id)
    abr = Map.get(params, :advanced_broker_relations, 0)

    for order <- orders do
      side = if order.buy, do: :buy, else: :sell

      book =
        Market.location_book(
          order.region_id,
          order.type_id,
          side,
          order.location_id,
          @own_book_depth
        )

      broker = StationQuery.fees(order.location_id, p).broker

      order
      |> Map.merge(OwnOrders.evaluate(order, book, own_ids, broker, abr))
      |> Map.put(:type_name, type_name(order.type_id))
    end
  end

  defp type_name(type_id) do
    case Eth.Sde.type(type_id) do
      %{name: name} -> name
      nil -> "##{type_id}"
    end
  end
end
