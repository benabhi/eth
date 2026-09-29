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

  Implementa: RF-4.13, RNF-1.2, RNF-9.1.
  """
  use GenServer

  alias Eth.{Clock, Events, GameRules, Sde}
  alias Eth.Engine.{Evaluator, Fees, Summary}
  alias Eth.Market.TableOwner

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

    stats = %{
      duration_ms: System.monotonic_time(:millisecond) - started,
      summaries_ms: summaries_ms,
      types: length(all_types),
      sources: length(sources),
      opportunities: length(opportunities)
    }

    {summarized, types, opportunities, stats}
  end

  defp source({{:region, id} = source, entry}) do
    %{source: source, tid: entry.tid, region_id: id, last_modified: entry.meta.last_modified}
  end

  defp publish({summarized, types, opportunities, stats}, state) do
    tid = :ets.new(:eth_opportunities, [:set, :public, read_concurrency: true])
    :ets.insert(tid, Enum.map(opportunities, &{&1.id, &1}))

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
