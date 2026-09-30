defmodule Eth.Threat.Baseline do
  @moduledoc """
  Línea base horaria del radar (RF-3.4, RF-3.7).

  - Descarga `/universe/system_kills` y `/universe/system_jumps` al vencer su `Expires`
    (caché de ESI de 1 h), con `If-None-Match`; pausa en el downtime.
  - Guarda cada hora en `system_activity_hourly` (la hora es el `Last-Modified` de ESI) y
    registra la hora muestreada en `system_activity_samples`. Retención de 30 días.
  - Recalcula la línea base (`Eth.Threat.BaselineModel`) con los últimos
    `:baseline_days` días y la publica en la ETS pública `eth_threat_baseline`.
  - En modo Replay no descarga: usa lo guardado.

  HTTP, escritura y cálculo corren en tareas supervisadas: el proceso nunca se bloquea.

  Implementa: RF-3.4, RF-3.7.
  """
  use GenServer

  import Ecto.Query

  alias Eth.{Clock, Events, GameRules, Market, Repo}
  alias Eth.Esi
  alias Eth.Esi.ServerStatus
  alias Eth.Market.RegionPoller
  alias Eth.Threat.BaselineModel

  @table :eth_threat_baseline
  @sources [:kills, :jumps]
  @chunk 5_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "λ del sistema para la franja horaria de `now` (kills esperadas en la ventana)."
  @spec lambda(pos_integer(), DateTime.t()) :: float()
  def lambda(system_id, %DateTime{hour: hour}), do: elem(entry(system_id).lambda, hour)

  @doc "Riesgo base del sistema (probabilidad por paso, RF-3.7)."
  @spec base_risk(pos_integer()) :: float()
  def base_risk(system_id), do: entry(system_id).base_risk

  @doc """
  Riesgo base de todos los sistemas en una sola lectura (para la consulta del motor):
  `%{by_system: %{id => riesgo}, quiet: %{banda => riesgo}}`; los sistemas sin actividad
  usan el de su banda.
  """
  @spec risk_snapshot() :: %{by_system: map(), quiet: map()}
  def risk_snapshot do
    lookup(:__risk__) ||
      %{
        by_system: %{},
        quiet:
          Map.new(
            [:highsec, :lowsec, :nullsec],
            &{&1, BaselineModel.quiet_band(&1, %{}, 0).base_risk}
          )
      }
  end

  @doc "Resumen para el Centro de control: horas muestreadas y último cálculo."
  @spec meta() :: map()
  def meta do
    case lookup(:__meta__) do
      nil -> %{kill_hours: 0, jump_hours: 0, systems: 0, computed_at: nil}
      meta -> meta
    end
  end

  defp entry(system_id) do
    case lookup(system_id) do
      nil ->
        band = BaselineModel.band(system_id)

        case lookup(:__meta__) do
          %{quiet: quiet} -> quiet[band]
          nil -> BaselineModel.quiet_band(band, %{}, 0)
        end

      entry ->
        entry
    end
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
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

    sources = Map.new(@sources, &{&1, %{etag: nil, expires: nil, timer: nil, failures: 0}})
    state = %{sources: sources, tasks: %{}, computing: nil, dirty: false}
    {:ok, state, {:continue, :start}}
  end

  @impl true
  def handle_continue(:start, state) do
    state = recompute(state)

    if Market.data_source() == :live,
      do: {:noreply, Enum.reduce(@sources, state, &schedule(&2, &1, 0))},
      else: {:noreply, state}
  end

  @impl true
  def handle_info({:tick, source}, state) do
    state = put_in(state.sources[source].timer, nil)

    if ServerStatus.downtime?() do
      until = ServerStatus.window_end(Clock.utc_now())
      {:noreply, schedule(state, source, Clock.ms_until(until) + jitter())}
    else
      etag = state.sources[source].etag

      task =
        Task.Supervisor.async_nolink(Eth.Threat.TaskSupervisor, fn -> fetch(source, etag) end)

      {:noreply, put_in(state.tasks[task.ref], source)}
    end
  end

  def handle_info({ref, result}, %{computing: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    publish(result)
    {:noreply, after_compute(state)}
  end

  def handle_info({ref, result}, state) when is_map_key(state.tasks, ref) do
    Process.demonitor(ref, [:flush])
    {source, tasks} = Map.pop(state.tasks, ref)
    {:noreply, handle_result(%{state | tasks: tasks}, source, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{computing: %Task{ref: ref}} = state) do
    Events.emit(:error, "Radar", "Falló el cálculo de la línea base: #{inspect(reason)}")
    {:noreply, after_compute(state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state)
      when is_map_key(state.tasks, ref) do
    {source, tasks} = Map.pop(state.tasks, ref)
    {:noreply, handle_result(%{state | tasks: tasks}, source, {:error, {:crash, reason}})}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  ## Descarga y almacenamiento (en tareas)

  defp fetch(source, etag) do
    request = if source == :kills, do: &Esi.system_kills/1, else: &Esi.system_jumps/1

    case request.(etag) do
      {:ok, %{status: 304} = resp} ->
        {:not_modified, resp.expires}

      {:ok, resp} ->
        hour = hour_of(resp.last_modified || Clock.utc_now())
        store(source, hour, resp.body || [])
        {:ok, resp.etag, resp.expires}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp store(:kills, hour, body) do
    rows =
      for %{"system_id" => id} = r <- body do
        %{
          solar_system_id: id,
          hour: hour,
          ship_kills: r["ship_kills"] || 0,
          pod_kills: r["pod_kills"] || 0,
          npc_kills: r["npc_kills"] || 0
        }
      end

    upsert(rows, [:ship_kills, :pod_kills, :npc_kills], "kills", hour)
  end

  defp store(:jumps, hour, body) do
    rows =
      for %{"system_id" => id} = r <- body,
          do: %{solar_system_id: id, hour: hour, jumps: r["ship_jumps"] || 0}

    upsert(rows, [:jumps], "jumps", hour)
  end

  defp upsert(rows, fields, source, hour) do
    rows
    |> Enum.chunk_every(@chunk)
    |> Enum.each(
      &Repo.insert_all("system_activity_hourly", &1,
        on_conflict: {:replace, fields},
        conflict_target: [:solar_system_id, :hour]
      )
    )

    Repo.insert_all("system_activity_samples", [%{source: source, hour: hour}],
      on_conflict: :nothing
    )
  end

  defp hour_of(%DateTime{} = dt), do: %{DateTime.truncate(dt, :second) | minute: 0, second: 0}

  defp handle_result(state, source, {:ok, etag, expires}) do
    state
    |> update_in([:sources, source], &%{&1 | etag: etag, expires: expires, failures: 0})
    |> schedule(source, next_delay(expires))
    |> recompute()
  end

  defp handle_result(state, source, {:not_modified, expires}) do
    state
    |> update_in([:sources, source], &%{&1 | expires: expires, failures: 0})
    |> schedule(source, next_delay(expires))
  end

  defp handle_result(state, source, {:error, {kind, until}})
       when kind in [:paused, :rate_limited] do
    schedule(state, source, Clock.ms_until(until) + jitter())
  end

  defp handle_result(state, source, {:error, reason}) do
    failures = state.sources[source].failures + 1
    delay = RegionPoller.backoff_ms(failures)

    Events.emit(
      :warning,
      "Radar",
      "Línea base (#{source}): #{inspect(reason)} · reintento en #{div(delay, 1000)} s"
    )

    state |> put_in([:sources, source, :failures], failures) |> schedule(source, delay)
  end

  ## Cálculo

  # Si llegan datos mientras se calcula, se marca para volver a calcular al terminar:
  # si no, la línea base quedaba sin esos datos hasta el ciclo siguiente.
  defp recompute(%{computing: %Task{}} = state), do: %{state | dirty: true}

  defp recompute(state) do
    task = Task.Supervisor.async_nolink(Eth.Threat.TaskSupervisor, &compute/0)
    %{state | computing: task, dirty: false}
  end

  defp after_compute(%{dirty: true} = state), do: recompute(%{state | computing: nil})
  defp after_compute(state), do: %{state | computing: nil}

  # Corre en la tarea: borra lo viejo, agrega por sistema y franja, y calcula.
  defp compute do
    r = GameRules.get(:radar)
    now = Clock.utc_now()

    Repo.delete_all(
      from a in "system_activity_hourly",
        where: a.hour < type(^ago(now, r.activity_retention_days), :utc_datetime)
    )

    Repo.delete_all(
      from s in "system_activity_samples",
        where: s.hour < type(^ago(now, r.activity_retention_days), :utc_datetime)
    )

    since = ago(now, r.baseline_days)

    kill_samples =
      from(s in "system_activity_samples",
        where: s.source == "kills" and s.hour >= type(^since, :utc_datetime),
        group_by: fragment("extract(hour from ?)::int", s.hour),
        select: {fragment("extract(hour from ?)::int", s.hour), count()}
      )
      |> Repo.all()
      |> Map.new()

    jump_hours =
      Repo.aggregate(
        from(s in "system_activity_samples",
          where: s.source == "jumps" and s.hour >= type(^since, :utc_datetime)
        ),
        :count
      )

    activity =
      from(a in "system_activity_hourly",
        where: a.hour >= type(^since, :utc_datetime),
        group_by: [a.solar_system_id, fragment("extract(hour from ?)::int", a.hour)],
        select:
          {a.solar_system_id, fragment("extract(hour from ?)::int", a.hour),
           sum(a.ship_kills + a.pod_kills), sum(a.ship_kills), sum(a.jumps)}
      )
      |> Repo.all()
      |> Enum.reduce(%{}, fn {system, hour, kills, ship_kills, jumps}, acc ->
        Map.update(
          acc,
          system,
          %{by_hour: %{hour => kills}, kills: kills, ship_kills: ship_kills, jumps: jumps},
          &%{
            &1
            | by_hour: Map.put(&1.by_hour, hour, kills),
              kills: &1.kills + kills,
              ship_kills: &1.ship_kills + ship_kills,
              jumps: &1.jumps + jumps
          }
        )
      end)

    %{
      entries: BaselineModel.compute(activity, kill_samples, jump_hours),
      meta: %{
        kill_samples: kill_samples,
        kill_hours: kill_samples |> Map.values() |> Enum.sum(),
        jump_hours: jump_hours,
        systems: map_size(activity),
        computed_at: now,
        quiet:
          Map.new(
            [:highsec, :lowsec, :nullsec],
            &{&1, BaselineModel.quiet_band(&1, kill_samples, jump_hours)}
          )
      }
    }
  end

  defp publish(%{entries: entries, meta: meta}) do
    :ets.delete_all_objects(@table)

    risk = %{
      by_system: Map.new(entries, fn {id, e} -> {id, e.base_risk} end),
      quiet: Map.new(meta.quiet, fn {band, e} -> {band, e.base_risk} end)
    }

    :ets.insert(@table, [{:__meta__, meta}, {:__risk__, risk} | Map.to_list(entries)])
    :telemetry.execute([:eth, :threat, :baseline], %{systems: meta.systems}, meta)
  end

  defp ago(now, days), do: DateTime.add(now, -days, :day) |> DateTime.truncate(:second)

  ## Utilidades

  defp next_delay(nil), do: 3_600_000
  defp next_delay(expires), do: Clock.ms_until(expires) + jitter()

  defp jitter, do: Enum.random(GameRules.get(:poll_jitter_ms))

  defp schedule(state, source, delay) do
    if t = state.sources[source].timer, do: Process.cancel_timer(t)
    timer = Process.send_after(self(), {:tick, source}, delay)
    put_in(state.sources[source].timer, timer)
  end
end
