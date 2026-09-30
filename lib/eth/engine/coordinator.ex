defmodule Eth.Engine.Coordinator do
  @moduledoc """
  Orquesta la evaluación del motor (RF-4.13).

  - Escucha `market:snapshots` y el estado del SDE; agrupa los cambios con un debounce
    de 2 s y corre una sola evaluación a la vez (los disparadores que llegan mientras
    tanto se acumulan en una sola evaluación siguiente).
  - La evaluación corre en una tarea supervisada: actualiza los resúmenes solo de las
    fuentes con generación nueva y recalcula las oportunidades.
  - Publica el resultado en una tabla ETS nueva, cambia el catálogo atómicamente
    (versión + 1) y borra la anterior tras un período de gracia. Anuncia la versión en
    `engine:opportunities`.
  - Declara a `Eth.Market.History` los pares (región, tipo) de las oportunidades, con
    prioridad por TVS preliminar (RF-1.12).
  - Evalúa también los candidatos de station trading de los hubs (RF-4.16) y los de la
    familia por órdenes entre estaciones (RF-4.1), y los publica en sus propias tablas
    (`current_station/0`, `current_orders/0`), con el mismo versionado.

  Implementa: RF-1.12, RF-4.13, RF-4.16, RNF-1.2, RNF-9.1.
  """
  use GenServer

  alias Eth.{Clock, Events, GameRules, Sde}

  alias Eth.Engine.{
    Evaluator,
    Fees,
    OrderEvaluator,
    Query,
    StationEvaluator,
    Summary
  }

  alias Eth.Market.{History, TableOwner}

  @catalog :eth_opportunities_catalog
  @topic "engine:opportunities"
  @debounce_ms 2_000
  @grace_ms 30_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Tópico con los anuncios de versión."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "Tabla vigente y metadatos (`nil` si todavía no hubo evaluación)."
  @spec current() :: {:ets.tid(), map()} | nil
  def current do
    if :ets.whereis(@catalog) != :undefined do
      case :ets.lookup(@catalog, :current) do
        [{:current, tid, meta}] -> {tid, meta}
        [] -> nil
      end
    end
  end

  @doc "Tabla vigente de candidatos de station trading (`nil` si todavía no hubo evaluación)."
  @spec current_station() :: :ets.tid() | nil
  def current_station do
    if :ets.whereis(@catalog) != :undefined do
      case :ets.lookup(@catalog, :station) do
        [{:station, tid}] -> tid
        [] -> nil
      end
    end
  end

  @doc "Tabla vigente de candidatos por órdenes entre estaciones (`nil` sin evaluación)."
  @spec current_orders() :: :ets.tid() | nil
  def current_orders do
    if :ets.whereis(@catalog) != :undefined do
      case :ets.lookup(@catalog, :orders) do
        [{:orders, tid}] -> tid
        [] -> nil
      end
    end
  end

  @doc "Pide una evaluación (con debounce)."
  @spec request() :: :ok
  def request do
    send(__MODULE__, :request)
    :ok
  end

  @impl true
  def init(_opts) do
    Summary.create_table()
    :ets.new(@catalog, [:named_table, :public, :set, read_concurrency: true])
    Phoenix.PubSub.subscribe(Eth.PubSub, "market:snapshots")
    Phoenix.PubSub.subscribe(Eth.PubSub, Sde.topic())

    state = %{summarized: %{}, types: %{}, task: nil, pending: false, timer: nil, version: 0}
    {:ok, schedule(state)}
  end

  @impl true
  def handle_info({:snapshot, _source, _generation}, state), do: {:noreply, schedule(state)}
  def handle_info({:sde_status, %{state: :ready}}, state), do: {:noreply, schedule(state)}
  def handle_info({:sde_status, _status}, state), do: {:noreply, state}
  def handle_info(:request, state), do: {:noreply, schedule(state)}

  def handle_info(:evaluate, %{task: %Task{}} = state),
    do: {:noreply, %{state | timer: nil, pending: true}}

  def handle_info(:evaluate, state) do
    state = %{state | timer: nil}

    if Sde.ready?() and TableOwner.all() != [] do
      {:noreply, start(state)}
    else
      {:noreply, state}
    end
  end

  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    state = publish(result, %{state | task: nil})
    state = if state.pending, do: schedule(%{state | pending: false}), else: state
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    Events.emit(:error, "Motor", "La evaluación falló: #{inspect(reason)}")
    {:noreply, %{state | task: nil}}
  end

  def handle_info({:drop, tid}, state) do
    if :ets.info(tid, :owner) == self(), do: :ets.delete(tid)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp schedule(%{timer: nil} = state),
    do: %{state | timer: Process.send_after(self(), :evaluate, @debounce_ms)}

  defp schedule(state), do: state

  defp start(state) do
    summarized = state.summarized
    types = state.types

    task =
      Task.Supervisor.async_nolink(Eth.Engine.TaskSupervisor, fn ->
        evaluate(summarized, types)
      end)

    %{state | task: task}
  end

  # Corre en la tarea: resúmenes incrementales + evaluación.
  defp evaluate(summarized, types) do
    started = System.monotonic_time(:millisecond)
    entries = TableOwner.all()
    sources = Enum.map(entries, &source/1)

    {summarized, types} =
      Enum.reduce(entries, {summarized, types}, fn {source, entry}, {sum, typ} ->
        if Map.get(sum, source) == entry.generation do
          {sum, typ}
        else
          {Map.put(sum, source, entry.generation),
           Map.put(typ, source, Summary.replace(source, entry.tid))}
        end
      end)

    # Fuentes que ya no existen: se borran sus resúmenes.
    current = MapSet.new(entries, &elem(&1, 0))
    gone = summarized |> Map.keys() |> Enum.reject(&MapSet.member?(current, &1))
    Enum.each(gone, &Summary.delete/1)
    summarized = Map.drop(summarized, gone)
    types = Map.drop(types, gone)

    all_types = types |> Map.values() |> List.flatten() |> Enum.uniq()
    summaries_ms = System.monotonic_time(:millisecond) - started

    opportunities =
      sources
      |> Evaluator.run(all_types,
        tax: Fees.sales_tax(GameRules.get(:guest_accounting_level)),
        min_profit: GameRules.get(:min_profit_isk)
      )
      |> Enum.sort_by(& &1.profit, :desc)
      |> Enum.take(GameRules.get(:max_universal_opportunities))

    direct_at = System.monotonic_time(:millisecond)
    stations = StationEvaluator.run(entries, types)
    station_at = System.monotonic_time(:millisecond)

    # Por órdenes: solo candidatos con historial en el hub y viables en el mejor caso; de
    # los demás se pide el historial (entran en la evaluación siguiente). Sin esto:
    # ~170.000 candidatos, ~380 MB y ~0,5 s por consulta (RNF-1.1).
    %{candidates: order_opps, missing_history: order_missing} =
      OrderEvaluator.run(sources, all_types)

    orders_at = System.monotonic_time(:millisecond)

    History.demand(
      history_demand(opportunities) ++
        station_history_demand(stations) ++ order_history_demand(order_missing)
    )

    stats = %{
      duration_ms: System.monotonic_time(:millisecond) - started,
      summaries_ms: summaries_ms,
      # Duración de cada etapa, para la barra segmentada del Centro de control (RF-8.10).
      direct_ms: direct_at - started - summaries_ms,
      station_ms: station_at - direct_at,
      orders_ms: orders_at - station_at,
      types: length(all_types),
      sources: length(sources),
      opportunities: length(opportunities),
      station_candidates: length(stations),
      order_candidates: length(order_opps)
    }

    {summarized, types, opportunities, stations, order_opps, stats}
  end

  # Historial de los hubs que todavía no lo tienen para candidatos por órdenes (tiempo de
  # ejecución), con prioridad baja; a lo sumo `:history_demand_max` pares.
  @doc false
  @spec order_history_demand([{pos_integer(), pos_integer()}]) :: [
          {{pos_integer(), pos_integer()}, number()}
        ]
  def order_history_demand(pairs) do
    pairs
    |> Enum.take(GameRules.get(:station_trading).history_demand_max)
    |> Enum.map(&{&1, 20.0})
  end

  # Historial para los candidatos de station trading: sin volumen no se proponen
  # (RF-4.16). Prioridad baja frente a los trades directos, creciente con el diferencial;
  # a lo sumo `:history_demand_max` pares por evaluación.
  @doc false
  @spec station_history_demand([Eth.Engine.StationOpportunity.t()]) :: [
          {{pos_integer(), pos_integer()}, number()}
        ]
  def station_history_demand(stations) do
    max = GameRules.get(:station_trading).history_demand_max

    stations
    |> Enum.map(fn st ->
      [{bid, _, _, _, _} | _] = st.bids
      [{ask, _, _, _, _} | _] = st.asks
      {{st.location.region_id, st.type_id}, min(40.0, (ask - bid) / bid * 100)}
    end)
    |> Enum.sort_by(&elem(&1, 1), :desc)
    |> Enum.take(max)
  end

  # Pares (región, tipo) cuyo historial hace falta, priorizados por el TVS preliminar del
  # modo invitado (RF-1.12). Los sospechosos sin historial van primero (AS-3); el
  # destino, apenas antes que el origen.
  @doc false
  @spec history_demand([Eth.Engine.Opportunity.t()]) :: [
          {{pos_integer(), pos_integer()}, number()}
        ]
  def history_demand(opportunities) do
    # Sin mínimo de beneficio: el universo ya pasó el filtro del motor.
    params = Map.put(Query.defaults(), :min_profit, 0)
    now = Clock.utc_now()

    for opp <- opportunities,
        row = Query.personalize(opp, params, now),
        row != nil,
        priority = row.tvs + if(unverified_suspect?(row), do: 100, else: 0),
        {loc, bump} <- [{opp.destination, 0.5}, {opp.origin, 0}],
        loc.region_id != nil do
      {{loc.region_id, opp.type_id}, priority + bump}
    end
  end

  defp unverified_suspect?(row),
    do: row.shield.status == :suspicious and row.history.destination == nil

  defp hub_region(%{mode: :listing} = opp), do: opp.destination.region_id
  defp hub_region(opp), do: opp.origin.region_id

  defp source({{:region, id} = source, entry}) do
    %{source: source, tid: entry.tid, region_id: id, last_modified: entry.meta.last_modified}
  end

  # Estructura (RF-1.6): su región viene en el meta que guarda el Fetcher.
  defp source({{:structure, _id} = source, entry}) do
    %{
      source: source,
      tid: entry.tid,
      region_id: entry.meta[:region_id],
      last_modified: entry.meta.last_modified
    }
  end

  defp publish({summarized, types, opportunities, stations, order_opps, stats}, state) do
    tid = :ets.new(:eth_opportunities, [:set, :public, read_concurrency: true])
    :ets.insert(tid, Enum.map(opportunities, &{&1.id, &1}))
    station_tid = :ets.new(:eth_station_opportunities, [:set, :public, read_concurrency: true])
    # Con la clave (región, tipo) aparte: la consulta filtra por historial sin copiar el
    # candidato completo (RNF-1.1).
    :ets.insert(
      station_tid,
      Enum.map(stations, &{&1.id, {&1.location.region_id, &1.type_id}, &1})
    )

    case current_station() do
      nil -> :ok
      old -> Process.send_after(self(), {:drop, old}, @grace_ms)
    end

    :ets.insert(@catalog, {:station, station_tid})

    orders_tid = :ets.new(:eth_order_opportunities, [:set, :public, read_concurrency: true])
    # Con el par (región del hub, tipo) aparte, como en station trading.
    :ets.insert(orders_tid, Enum.map(order_opps, &{&1.id, {hub_region(&1), &1.type_id}, &1}))

    case current_orders() do
      nil -> :ok
      old -> Process.send_after(self(), {:drop, old}, @grace_ms)
    end

    :ets.insert(@catalog, {:orders, orders_tid})

    version = state.version + 1
    meta = Map.merge(stats, %{version: version, evaluated_at: Clock.utc_now()})

    case current() do
      {old, _meta} -> Process.send_after(self(), {:drop, old}, @grace_ms)
      nil -> :ok
    end

    :ets.insert(@catalog, {:current, tid, meta})
    :telemetry.execute([:eth, :engine, :evaluate], %{duration_ms: stats.duration_ms}, stats)
    Phoenix.PubSub.broadcast(Eth.PubSub, @topic, {:opportunities_updated, meta})

    if version == 1 do
      Events.emit(
        :info,
        "Motor",
        "Primera evaluación: #{stats.opportunities} oportunidades de #{stats.types} tipos en #{stats.duration_ms} ms"
      )
    end

    %{state | summarized: summarized, types: types, version: version}
  end
end
