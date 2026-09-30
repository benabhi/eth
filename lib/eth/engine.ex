defmodule Eth.Engine do
  @moduledoc """
  API pública del motor de evaluación para la web y otros contextos (RNF-7.3).

  Implementa: RF-4.8, RF-4.12, RF-4.13, RF-4.14, RF-6.5.
  """

  alias Eth.{Clock, Events, GameRules, Market, Repo}

  alias Eth.Engine.{
    Coordinator,
    Locations,
    Opportunity,
    OrderOpportunity,
    OrderQuery,
    OwnOrders,
    PublishLocations,
    Query,
    RouteRisk,
    SaleQuote,
    ScamReport,
    StationOpportunity,
    StationQuery,
    Summary
  }

  alias Eth.Market.{History, TableOwner}

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
