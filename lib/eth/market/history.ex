defmodule Eth.Market.History do
  @moduledoc """
  Historial de mercado bajo demanda (RF-1.12).

  - **Demanda:** el motor declara con `demand/1` los pares `(región, tipo)` relevantes y
    su prioridad (TVS preliminar). Cada declaración reemplaza a la anterior: después del
    downtime se refrescan solo los pares que sigan siendo relevantes.
  - **Cola:** se atiende de mayor a menor prioridad, salteando los pares con estadísticas
    vigentes (un par consultado hoy no se vuelve a pedir: ESI lo actualiza una vez por
    día, `Eth.Market.HistoryStats.fresh?/2`).
  - **Ritmo:** nunca más de `:history_max_per_min` requests en una ventana deslizante de
    60 s (`Eth.Market.RateWindow`; límite de ESI: 300/min) y como mucho
    `:history_concurrency` en vuelo.
  - **Pausas:** en el downtime espera al final de la ventana; ante una pausa de ESI
    (error limit, 420), hasta que se levante; ante errores seguidos, backoff.
  - **Almacenamiento:** caché caliente en la ETS pública `eth_history_stats` y copia en
    PostgreSQL (`market_history_stats`), que se recarga al arrancar. En modo Replay no se
    llama a ESI: se usa solo lo guardado.
  - Anuncia en `market:history` (`{:history_updated, n}`, agrupado cada
    `:history_announce_ms`) para que el Cazador vuelva a consultar.

  La descarga y la escritura corren en tareas supervisadas: el proceso nunca se bloquea.

  Implementa: RF-1.12, RNF-3.5.
  """
  use GenServer

  import Ecto.Query

  alias Eth.{Clock, Events, GameRules, Market, Repo}
  alias Eth.Esi
  alias Eth.Esi.ServerStatus
  alias Eth.Market.{HistoryStat, HistoryStats, RateWindow, RegionPoller}

  @table :eth_history_stats
  @topic "market:history"
  @window_ms 60_000
  @retention_days 30

  @type pair :: {pos_integer(), pos_integer()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Tópico con los anuncios de estadísticas nuevas."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "Estadísticas de un tipo en una región (`nil` si todavía no hay historial)."
  @spec stats(pos_integer(), pos_integer()) :: HistoryStats.t() | nil
  def stats(region_id, type_id) do
    case :ets.whereis(@table) do
      :undefined ->
        nil

      table ->
        case :ets.lookup(table, {region_id, type_id}) do
          [{_pair, stats}] -> stats
          [] -> nil
        end
    end
  end

  @doc """
  Declara los pares relevantes con su prioridad (mayor = antes). Reemplaza la demanda
  anterior. No bloquea: si el proceso no corre, no hace nada.
  """
  @spec demand([{pair(), number()}]) :: :ok
  def demand(pairs) do
    if Process.whereis(__MODULE__), do: GenServer.cast(__MODULE__, {:demand, pairs})
    :ok
  end

  @doc "Estado para el Centro de control: cola, en vuelo, requests del último minuto, caché."
  @spec status() :: map()
  def status, do: GenServer.call(__MODULE__, :status)

  ## Callbacks

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

    state = %{
      queue: [],
      inflight: %{},
      window: RateWindow.new(GameRules.get(:history_max_per_min), @window_ms),
      timer: nil,
      failures: 0,
      unannounced: 0,
      announce_timer: nil
    }

    {:ok, state, {:continue, :load}}
  end

  # Recarga la copia de PostgreSQL (vigente o no: una estadística de ayer sigue siendo
  # mejor que ninguna para el anti-scam) y borra las filas viejas.
  @impl true
  def handle_continue(:load, state) do
    cutoff = Date.add(HistoryStats.last_day(Clock.utc_now()), -@retention_days)
    Repo.delete_all(from s in HistoryStat, where: s.as_of < ^cutoff)

    HistoryStat
    |> Repo.all()
    |> Enum.map(&{{&1.region_id, &1.type_id}, HistoryStat.to_stats(&1)})
    |> then(&:ets.insert(@table, &1))

    {:noreply, state}
  end

  @impl true
  def handle_cast({:demand, pairs}, state) do
    queue =
      pairs
      |> Enum.sort_by(&elem(&1, 1), :desc)
      |> Enum.map(&elem(&1, 0))
      |> Enum.uniq()

    {:noreply, pump(%{state | queue: queue})}
  end

  @impl true
  def handle_call(:status, _from, state) do
    now = Clock.utc_now()

    pending =
      Enum.count(state.queue, fn pair ->
        not Map.has_key?(state.inflight, pair) and not fresh?(pair, now)
      end)

    reply = %{
      pending: pending,
      inflight: map_size(state.inflight),
      last_minute: RateWindow.count(state.window, mono()),
      max_per_min: state.window.max,
      cached: :ets.info(@table, :size)
    }

    {:reply, reply, state}
  end

  @impl true
  def handle_info(:tick, state), do: {:noreply, pump(%{state | timer: nil})}

  def handle_info({ref, result}, state) when is_map_key(state.inflight, ref) do
    Process.demonitor(ref, [:flush])
    {pair, inflight} = Map.pop(state.inflight, ref)
    {:noreply, state |> Map.put(:inflight, inflight) |> handle_result(pair, result) |> pump()}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state)
      when is_map_key(state.inflight, ref) do
    {pair, inflight} = Map.pop(state.inflight, ref)
    state = handle_result(%{state | inflight: inflight}, pair, {:error, {:crash, reason}})
    {:noreply, pump(state)}
  end

  def handle_info(:announce, state) do
    Phoenix.PubSub.broadcast(Eth.PubSub, @topic, {:history_updated, state.unannounced})
    {:noreply, %{state | unannounced: 0, announce_timer: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  ## Cola

  # Lanza requests mientras haya lugar en vuelo, presupuesto en la ventana y pares
  # pendientes. Si falta presupuesto, reprograma para cuando se libere.
  defp pump(%{timer: timer} = state) when timer != nil, do: state

  defp pump(state) do
    cond do
      Market.data_source() == :replay ->
        state

      ServerStatus.downtime?() ->
        until = ServerStatus.window_end(Clock.utc_now())
        schedule(state, Clock.ms_until(until) + Enum.random(0..30_000))

      map_size(state.inflight) >= GameRules.get(:history_concurrency) ->
        state

      true ->
        dispatch(state)
    end
  end

  defp dispatch(state) do
    now = Clock.utc_now()
    inflight_pairs = state.inflight |> Map.values() |> MapSet.new()
    queue = Enum.drop_while(state.queue, &(MapSet.member?(inflight_pairs, &1) or fresh?(&1, now)))

    case queue do
      [] ->
        %{state | queue: []}

      [pair | rest] ->
        case RateWindow.take(state.window, mono()) do
          {:wait, ms} ->
            schedule(%{state | queue: queue}, ms)

          {:ok, window} ->
            task = Task.Supervisor.async_nolink(Eth.Market.TaskSupervisor, fn -> fetch(pair) end)
            state = %{state | queue: rest, window: window}
            pump(%{state | inflight: Map.put(state.inflight, task.ref, pair)})
        end
    end
  end

  defp fresh?(pair, now) do
    case :ets.lookup(@table, pair) do
      [{_pair, stats}] -> HistoryStats.fresh?(stats, now)
      [] -> false
    end
  end

  # Corre en la tarea: descarga, calcula y guarda (ETS + PostgreSQL).
  defp fetch({region_id, type_id} = pair) do
    now = Clock.utc_now()
    as_of = HistoryStats.last_day(now)

    result =
      case Esi.market_history(region_id, type_id) do
        {:ok, resp} ->
          {:ok, HistoryStats.compute(resp.body || [], as_of)}

        # Tipo sin mercado en la región: estadísticas vacías, no se vuelve a pedir hoy.
        {:error, {:http, %{status: status}}} when status in [400, 404, 422] ->
          {:ok, HistoryStats.compute([], as_of)}

        {:error, reason} ->
          {:error, reason}
      end

    with {:ok, stats} <- result, do: store(pair, stats, now)
    :telemetry.execute([:eth, :market, :history, :fetch], %{count: 1}, %{ok: ok?(result)})
    result
  end

  defp ok?({:ok, _}), do: true
  defp ok?(_error), do: false

  defp store({region_id, type_id} = pair, stats, now) do
    Repo.insert_all(HistoryStat, [HistoryStat.row(region_id, type_id, stats, now)],
      on_conflict: {:replace_all_except, [:region_id, :type_id]},
      conflict_target: [:region_id, :type_id]
    )

    :ets.insert(@table, {pair, stats})
  end

  defp handle_result(state, _pair, {:ok, _stats}) do
    state = %{state | failures: 0, unannounced: state.unannounced + 1}

    if state.announce_timer do
      state
    else
      timer = Process.send_after(self(), :announce, GameRules.get(:history_announce_ms))
      %{state | announce_timer: timer}
    end
  end

  # Pausa de ESI: el par vuelve al frente de la cola y se espera a que se levante.
  defp handle_result(state, pair, {:error, {kind, until}})
       when kind in [:paused, :rate_limited] do
    schedule(%{state | queue: [pair | state.queue]}, Clock.ms_until(until) + 1_000)
  end

  # Otro error: el par se descarta hasta la próxima demanda y se espera con backoff.
  defp handle_result(state, {region_id, type_id}, {:error, reason}) do
    failures = state.failures + 1
    delay = RegionPoller.backoff_ms(failures)

    if failures in [1, GameRules.get(:circuit_breaker_failures)] do
      Events.emit(
        :warning,
        "Historial",
        "Error en #{region_id}/#{type_id}: #{inspect(reason)} · reintento en #{div(delay, 1000)} s"
      )
    end

    schedule(%{state | failures: failures}, delay)
  end

  defp schedule(state, delay_ms) do
    if state.timer, do: Process.cancel_timer(state.timer)
    %{state | timer: Process.send_after(self(), :tick, delay_ms)}
  end

  defp mono, do: System.monotonic_time(:millisecond)
end
