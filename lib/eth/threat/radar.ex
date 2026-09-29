defmodule Eth.Threat.Radar do
  @moduledoc """
  Mapa de calor de amenazas en memoria (RF-3.3, RF-3.5, RF-3.6, RF-3.8).

  - Recibe las kills normalizadas del feed (`ingest/1`) y guarda por sistema las de la
    ventana `W`; las que ya salieron de la ventana (o vienen del futuro) se descartan.
  - Por sistema con kills calcula `N`, la intensidad con decaimiento, λ de la línea base,
    la alerta (Poisson), el índice de amenaza y, si hay alerta, la clasificación.
  - Publica en la ETS pública `eth_threat_heat` (`system_id → estado`, más `:__meta__`
    con la versión y el estado degradado) y anuncia los cambios en `threat:heatmap`
    (`{:heatmap, versión}`); las kills relevantes (transportes, gates, sistemas en alerta)
    van a `threat:kills`.
  - Cada `@tick_ms` recalcula el decaimiento y vence kills. Si el feed no entrega kills
    durante `:feed_stale_s`, el radar queda **degradado**: se usa solo la línea base
    (RF-3.8).

  Implementa: RF-3.3, RF-3.5, RF-3.6, RF-3.8.
  """
  use GenServer

  alias Eth.{Clock, Events, GameRules, Sde}
  alias Eth.Threat.{Baseline, Classifier, Detector, KillFeed, Killmail}

  @table :eth_threat_heat
  @heat_topic "threat:heatmap"
  @kills_topic "threat:kills"
  @tick_ms 30_000
  @recent 50
  @future_tolerance_s 300

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Tópico con los cambios del mapa de calor."
  @spec heat_topic() :: String.t()
  def heat_topic, do: @heat_topic

  @doc "Tópico con las kills relevantes."
  @spec kills_topic() :: String.t()
  def kills_topic, do: @kills_topic

  @doc "Entrega una kill normalizada (la llaman los feeds)."
  @spec ingest(Killmail.t()) :: :ok
  def ingest(%Killmail{} = kill), do: GenServer.cast(__MODULE__, {:ingest, kill})

  @doc "Estado de un sistema (`nil` si no tiene kills en la ventana)."
  @spec system(pos_integer()) :: map() | nil
  def system(system_id), do: lookup(system_id)

  @doc "Índice de amenaza 0–1 de un sistema (0 sin alerta)."
  @spec threat(pos_integer()) :: float()
  def threat(system_id) do
    case lookup(system_id) do
      %{threat: threat} -> threat
      nil -> 0.0
    end
  end

  @doc "Sistemas con kills en la ventana, de mayor a menor amenaza e intensidad."
  @spec hot_systems() :: [map()]
  def hot_systems do
    case :ets.whereis(@table) do
      :undefined ->
        []

      table ->
        table
        |> :ets.tab2list()
        |> Enum.reject(fn {key, _} -> key == :__meta__ end)
        |> Enum.map(&elem(&1, 1))
        |> Enum.sort_by(&{-&1.threat, -&1.intensity})
    end
  end

  @doc "Versión del mapa de calor y estado degradado."
  @spec meta() :: %{version: non_neg_integer(), degraded: boolean()}
  def meta, do: lookup(:__meta__) || %{version: 0, degraded: true}

  @doc "¿Radar degradado? (sin feed en vivo: solo línea base, RF-3.8)."
  @spec degraded?() :: boolean()
  def degraded?, do: meta().degraded

  @doc "Últimas kills relevantes (más recientes primero)."
  @spec recent_kills() :: [map()]
  def recent_kills do
    if Process.whereis(__MODULE__), do: GenServer.call(__MODULE__, :recent), else: []
  catch
    :exit, _ -> []
  end

  defp lookup(key) do
    case :ets.whereis(@table) do
      :undefined ->
        nil

      table ->
        case :ets.lookup(table, key) do
          [{^key, value}] -> value
          [] -> nil
        end
    end
  end

  ## Callbacks

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    now = Clock.utc_now()

    state = %{
      kills: restore(now),
      recent: [],
      last_kill_at: nil,
      started_at: now,
      version: 0,
      degraded: nil
    }

    Enum.each(state.kills, fn {system_id, kills} -> update_system(system_id, kills, now) end)
    Process.send_after(self(), :tick, @tick_ms)
    {:ok, publish_meta(state, now)}
  end

  @impl true
  def terminate(_reason, state), do: save(state.kills)

  @impl true
  def handle_cast({:ingest, kill}, state) do
    now = Clock.utc_now()
    state = %{state | last_kill_at: now}
    state = if in_window?(kill, now), do: add_kill(state, kill, now), else: state
    {:noreply, publish_meta(state, now)}
  end

  # Los datos vienen de un tercero: una kill que no se puede procesar se registra y se
  # descarta, en lugar de tirar abajo el radar (y con él las kills de la ventana).
  defp add_kill(state, kill, now) do
    kills = Map.update(state.kills, kill.system_id, [kill], &[kill | &1])
    {changed?, entry} = update_system(kill.system_id, kills[kill.system_id], now)
    state = remember(%{state | kills: kills}, kill, entry)
    if changed?, do: bump(state), else: state
  rescue
    error ->
      Events.emit(:warning, "Radar", "Kill #{kill.id} descartada: #{Exception.message(error)}")
      state
  end

  @impl true
  def handle_call(:recent, _from, state), do: {:reply, state.recent, state}

  @impl true
  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, @tick_ms)
    now = Clock.utc_now()

    {kills, changed?} =
      Enum.reduce(state.kills, {%{}, false}, fn {system_id, list}, {acc, changed?} ->
        case Detector.in_window(list, now) do
          [] ->
            :ets.delete(@table, system_id)
            {acc, true}

          current ->
            {c, _entry} = update_system(system_id, current, now)
            {Map.put(acc, system_id, current), changed? or c}
        end
      end)

    state = %{state | kills: kills}
    save(kills)
    state = if changed?, do: bump(state), else: state
    {:noreply, publish_meta(state, now)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  ## Cálculo

  defp in_window?(kill, now) do
    age = DateTime.diff(now, kill.time)
    age <= GameRules.get(:radar).window_min * 60 and age >= -@future_tolerance_s
  end

  # Recalcula un sistema; devuelve si cambió algo que afecte a las rutas.
  defp update_system(system_id, kills, now) do
    kills = Detector.in_window(kills, now)
    n = length(kills)
    intensity = Detector.intensity(kills, now)
    lambda = Baseline.lambda(system_id, now)
    alert = Detector.alert?(n, lambda)
    security = (Sde.system(system_id) || %{})[:security]

    entry = %{
      system_id: system_id,
      kills: n,
      intensity: intensity,
      lambda: lambda,
      alert: alert,
      threat: Detector.threat(alert, intensity, lambda),
      classification: if(alert, do: Classifier.classify(kills, security)),
      updated_at: now
    }

    previous = lookup(system_id)
    :ets.insert(@table, {system_id, entry})

    if alert and not match?(%{alert: true}, previous) do
      Events.emit(
        :warning,
        "Radar",
        "Alerta en #{system_name(system_id)}: #{entry.classification.description}"
      )
    end

    {changed?(previous, entry), entry}
  end

  defp changed?(nil, entry), do: entry.alert

  defp changed?(previous, entry) do
    previous.alert != entry.alert or abs(previous.threat - entry.threat) >= 0.05 or
      (entry.classification && previous.classification &&
         previous.classification.type != entry.classification.type) == true
  end

  defp bump(state) do
    version = state.version + 1
    Phoenix.PubSub.broadcast(Eth.PubSub, @heat_topic, {:heatmap, version})
    %{state | version: version}
  end

  # Kills relevantes para el panel: transportes, en un gate o en un sistema en alerta.
  defp remember(state, kill, entry) do
    if kill.victim_transport or kill.gate_id != nil or entry.alert do
      summary = %{
        id: kill.id,
        time: kill.time,
        system_id: kill.system_id,
        system_name: system_name(kill.system_id),
        victim_type_id: kill.victim_type_id,
        victim_transport: kill.victim_transport,
        gate_to: kill.gate_destination_id && system_name(kill.gate_destination_id),
        attackers: kill.attacker_count,
        value: kill.value,
        alert: entry.alert
      }

      Phoenix.PubSub.broadcast(Eth.PubSub, @kills_topic, {:kill, summary})
      %{state | recent: Enum.take([summary | state.recent], @recent)}
    else
      state
    end
  end

  # Degradado si no llegan kills del feed durante `:feed_stale_s` (con gracia al arrancar)
  # o si el feed está apagado.
  defp publish_meta(state, now) do
    stale_s = GameRules.get(:radar).feed_stale_s
    since = state.last_kill_at || state.started_at

    degraded = KillFeed.impl() == nil or DateTime.diff(now, since) > stale_s

    if state.degraded != nil and degraded != state.degraded do
      if degraded,
        do:
          Events.emit(:warning, "Radar", "Radar degradado: sin kills del feed, solo línea base"),
        else: Events.emit(:info, "Radar", "Radar en vivo: el feed vuelve a entregar kills")

      Phoenix.PubSub.broadcast(Eth.PubSub, @heat_topic, {:heatmap, state.version})
    end

    :ets.insert(
      @table,
      {:__meta__, %{version: state.version, degraded: degraded, updated_at: now}}
    )

    %{state | degraded: degraded}
  end

  defp system_name(id), do: (Sde.system(id) || %{name: "#{id}"}).name

  ## Persistencia (reinicio en caliente y modo Replay)

  @doc "Archivo con las kills de la ventana en el directorio `threat` (vivo) o `replay`."
  @spec kills_file(String.t()) :: Path.t()
  def kills_file(dir) when dir in ["threat", "replay"],
    do: Path.join(Eth.Storage.path(dir), "kills.json")

  # En modo Replay no se guarda: serían las mismas kills reproducidas.
  # La ruta es un literal del directorio de datos, nunca entrada externa.
  # sobelow_skip ["Traversal.FileModule"]
  defp save(kills) do
    if Eth.Market.data_source() == :live do
      path = kills_file("threat")
      json = kills |> Map.values() |> List.flatten() |> Enum.map(&Killmail.to_json/1)

      with :ok <- File.write(path <> ".tmp", Jason.encode!(json)),
           do: File.rename(path <> ".tmp", path)
    end

    :ok
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp restore(now) do
    with true <- Eth.Market.data_source() == :live,
         {:ok, json} <- File.read(kills_file("threat")),
         {:ok, list} when is_list(list) <- Jason.decode(json) do
      list
      |> Enum.map(&Killmail.from_json/1)
      |> Enum.filter(&(&1 && in_window?(&1, now)))
      |> Enum.group_by(& &1.system_id)
    else
      _ -> %{}
    end
  end
end
