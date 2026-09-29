defmodule Eth.Tracking.RunMonitor do
  @moduledoc """
  Acompaña un viaje (RF-7.2 a RF-7.5). Un proceso por viaje activo o cerrado sin reconciliar.

  - **Etapas:** se registra como observador de la sesión del personaje (polling activo:
    ubicación cada 10 s, saldo cada 2 min) y avanza con `Eth.Tracking.Stages`.
  - **Revalidación (RF-7.3):** con cada evaluación del motor recotiza la venta en el destino;
    avisa si el beneficio cae más de `:revalidate_drop` o si las órdenes ya no alcanzan. Con
    la carga comprada sugiere otro destino si el neto mejora más de `:reroute_gain`.
  - **Amenazas (RF-7.4):** con cada cambio del radar mira la ruta restante; ante una alerta
    nueva ofrece la ruta evasiva (+N saltos), que se aplica con un clic.
  - **Cierre (RF-7.5):** sincroniza `/wallet/transactions` al vencer su caché (1 h) y
    reconcilia; si la reconciliación queda incompleta, reintenta hasta `:reconcile_grace_min`
    después del cierre y guarda lo que haya.

  HTTP y base corren en tareas supervisadas.

  Implementa: RF-7.2, RF-7.3, RF-7.4, RF-7.5.
  """
  use GenServer, restart: :transient

  alias Eth.{Characters, Clock, Engine, Events, GameRules, Routing, Sde, Threat, Tracking}
  alias Eth.Characters.{Session, Sessions}
  alias Eth.Engine.Locations
  alias Eth.Esi
  alias Eth.Tracking.{Reconcile, Run, Stages}

  @sync_fallback_ms 3_600_000

  ## API

  @doc "Arranca el monitor de un viaje."
  @spec start(Run.t()) :: :ok
  def start(%Run{} = run) do
    if Process.whereis(Eth.Tracking.RunSupervisor) do
      DynamicSupervisor.start_child(Eth.Tracking.RunSupervisor, {__MODULE__, run})
    end

    :ok
  end

  @doc "Detiene el monitor de un viaje."
  @spec stop(pos_integer()) :: :ok
  def stop(run_id) do
    case whereis(run_id) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(Eth.Tracking.RunSupervisor, pid)
    end

    :ok
  end

  @doc "Estado en vivo: revalidación, amenazas y ruta evasiva (`nil` sin monitor)."
  @spec live(pos_integer()) :: map() | nil
  def live(run_id) do
    case whereis(run_id) do
      nil -> nil
      pid -> GenServer.call(pid, :live)
    end
  catch
    :exit, _ -> nil
  end

  @doc "Fija en el juego la ruta evasiva sugerida (RF-7.4)."
  @spec apply_evasive(pos_integer()) :: :ok | {:error, term()}
  def apply_evasive(run_id) do
    case whereis(run_id) do
      nil -> {:error, :no_monitor}
      pid -> GenServer.call(pid, :apply_evasive, 30_000)
    end
  end

  @spec start_link(Run.t()) :: GenServer.on_start()
  def start_link(run), do: GenServer.start_link(__MODULE__, run, name: via(run.id))

  @spec child_spec(Run.t()) :: Supervisor.child_spec()
  def child_spec(run),
    do: %{id: {__MODULE__, run.id}, start: {__MODULE__, :start_link, [run]}, restart: :transient}

  defp via(id), do: {:via, Registry, {Eth.Tracking.Registry, id}}

  defp whereis(id) do
    GenServer.whereis(via(id))
  rescue
    ArgumentError -> nil
  end

  ## Callbacks

  @impl true
  def init(run) do
    if Run.active?(run) do
      Phoenix.PubSub.subscribe(Eth.PubSub, Session.topic(run.character_id))
      Phoenix.PubSub.subscribe(Eth.PubSub, Engine.topic())
      Phoenix.PubSub.subscribe(Eth.PubSub, Threat.heat_topic())
    end

    # Confirmaciones manuales y cierres hechos desde la web.
    Phoenix.PubSub.subscribe(Eth.PubSub, Tracking.topic(run.character_id))

    state = %{
      run: run,
      location: nil,
      wallet: nil,
      revalidation: nil,
      threats: [],
      evasive: nil,
      sync: %{etag: nil, task: nil}
    }

    {:ok, state, {:continue, :start}}
  end

  @impl true
  def handle_continue(:start, state) do
    # Observador de la sesión: pasa a polling activo mientras dure el viaje.
    context = if Run.active?(state.run), do: Sessions.watch(state.run.character_id)
    state = state |> absorb(context) |> check_threats() |> revalidate()
    send(self(), :sync)
    {:noreply, state}
  end

  @impl true
  def handle_call(:live, _from, state) do
    reply = %{
      location: state.location,
      wallet: state.wallet,
      revalidation: state.revalidation,
      threats: state.threats,
      evasive: state.evasive
    }

    {:reply, reply, state}
  end

  def handle_call(:apply_evasive, _from, %{evasive: %{waypoints: [_ | _] = ids}} = state) do
    result = Characters.set_waypoints(state.run.character_id, ids)
    if result == :ok, do: Events.emit(:action, "Viajes", "Ruta evasiva fijada en el juego")
    {:reply, result, state}
  end

  def handle_call(:apply_evasive, _from, state), do: {:reply, {:error, :no_evasive}, state}

  @impl true
  def handle_info({:character, _id, {:updated, resource}, public}, state)
      when resource in [:location, :wallet] do
    {:noreply, state |> absorb(public) |> step() |> check_threats()}
  end

  # El viaje cambió (también por una confirmación manual): se toma la versión nueva.
  def handle_info({:run, %Run{id: id} = run, _extra}, %{run: %{id: id}} = state) do
    if run.status == "closed" and state.run.status != "closed", do: send(self(), :sync)
    {:noreply, %{state | run: run}}
  end

  def handle_info({:run, _other, _extra}, state), do: {:noreply, state}

  def handle_info({:opportunities_updated, _meta}, state), do: {:noreply, revalidate(state)}
  def handle_info({:heatmap, _version}, state), do: {:noreply, check_threats(state)}

  def handle_info(:sync, %{sync: %{task: %Task{}}} = state), do: {:noreply, state}

  def handle_info(:sync, state) do
    %{character_id: id} = state.run
    etag = state.sync.etag

    task =
      Task.Supervisor.async_nolink(Eth.Tracking.TaskSupervisor, fn ->
        fetch_transactions(id, etag)
      end)

    {:noreply, put_in(state.sync.task, task)}
  end

  def handle_info({ref, result}, %{sync: %{task: %Task{ref: ref}}} = state) do
    Process.demonitor(ref, [:flush])

    {etag, delay} =
      case result do
        {:ok, etag, %DateTime{} = expires} -> {etag, Clock.ms_until(expires) + 5_000}
        {:ok, etag, nil} -> {etag, @sync_fallback_ms}
        _error -> {state.sync.etag, @sync_fallback_ms}
      end

    Process.send_after(self(), :sync, delay)
    reconcile(%{state | sync: %{etag: etag, task: nil}})
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{sync: %{task: %Task{ref: ref}}} = state
      ) do
    Process.send_after(self(), :sync, @sync_fallback_ms)
    {:noreply, put_in(state.sync.task, nil)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  ## Etapas (RF-7.2)

  # Toma ubicación y saldo del contexto de la sesión.
  defp absorb(state, nil), do: state

  defp absorb(state, public) do
    context = public[:context] || %{}

    %{
      state
      | location: context[:location] || state.location,
        wallet: context[:wallet] || state.wallet
    }
  end

  defp step(%{run: run} = state) do
    if Run.active?(run) do
      signals = %{
        docked_at: docked_at(state.location),
        wallet: state.wallet,
        moved: moved?(state)
      }

      next =
        Stages.next(
          %{status: run.status, plan: run.plan, wallet_at_start: run.wallet_at_start},
          signals
        )

      run = Tracking.advance(run, next, "automático")
      state = %{state | run: run}
      if next == "closed", do: send(self(), :sync)
      state
    else
      state
    end
  end

  defp docked_at(nil), do: nil
  defp docked_at(location), do: location[:station_id] || location[:structure_id]

  # El piloto se movió si ya no está en el sistema ni atracado donde empezó el viaje.
  defp moved?(%{location: nil}), do: false

  defp moved?(%{run: run, location: location}) do
    start = run.plan["start_system_id"]
    start != nil and location[:solar_system_id] != start
  end

  ## Revalidación (RF-7.3)

  defp revalidate(%{run: run} = state) do
    if Run.active?(run) do
      plan = run.plan
      rules = GameRules.get(:run)
      tax = plan["tax_rate"] || 0.0
      quantity = plan["quantity"]
      destination = location(plan["destination_location_id"], plan["destination_system_id"])
      quote = Engine.sale_quote(plan["type_id"], destination, quantity, tax)
      profit = quote.net - plan["cost"]
      drop = if plan["profit"] > 0, do: (plan["profit"] - profit) / plan["profit"], else: 0.0

      alerts =
        [
          quote.quantity < quantity &&
            "Las órdenes de compra del destino ya no alcanzan: #{quote.quantity} de #{quantity}",
          drop > rules.revalidate_drop &&
            "El beneficio proyectado cayó #{round(drop * 100)} %"
        ]
        |> Enum.filter(&is_binary/1)

      info = %{
        at: Clock.utc_now(),
        profit: profit,
        drop: drop,
        alerts: alerts,
        suggestion: suggestion(run, quote, quantity, tax, rules)
      }

      notify_changes(state.revalidation, info, run)
      %{state | revalidation: info}
    else
      state
    end
  end

  # Con la carga comprada, otro destino que mejore el neto más de `:reroute_gain`.
  defp suggestion(%{status: status} = run, dest_quote, quantity, tax, rules)
       when status in ["bought", "in_transit", "at_destination"] do
    plan = run.plan

    plan["type_id"]
    |> Engine.sale_quotes(quantity, tax)
    |> Enum.find(&(&1.location_id != plan["destination_location_id"] and &1.quantity == quantity))
    |> case do
      %{net: net} = best when net >= dest_quote.net * (1 + rules.reroute_gain) ->
        from = plan["destination_system_id"]

        %{
          location_id: best.location_id,
          name: Locations.describe(best.location_id, best.system_id).name,
          gain: net - dest_quote.net,
          extra_jumps: Routing.distance(from, best.system_id, :shortest) || 0
        }

      _ ->
        nil
    end
  end

  defp suggestion(_run, _quote, _quantity, _tax, _rules), do: nil

  defp notify_changes(previous, info, run) do
    old = (previous && previous.alerts) || []

    for alert <- info.alerts -- old do
      Events.emit(:warning, "Viajes", "#{run.plan["type_name"]}: #{alert}")
      Tracking.broadcast(run, {:alert, alert})
    end

    if info.suggestion && !(previous && previous.suggestion) do
      s = info.suggestion

      Tracking.broadcast(
        run,
        {:alert,
         "Mejor destino: #{s.name} (+#{round(s.gain / 1.0e6)}M, #{s.extra_jumps} saltos desde el destino)"}
      )
    end

    Tracking.broadcast(run, :revalidated)
  end

  ## Amenazas en la ruta restante (RF-7.4)

  defp check_threats(%{run: run} = state) do
    if Run.active?(run) do
      alerts = Threat.hot_systems() |> Enum.filter(& &1.alert) |> Map.new(&{&1.system_id, &1})
      path = remaining_path(state)

      threats =
        path
        |> Enum.with_index()
        |> Enum.filter(fn {s, _i} -> Map.has_key?(alerts, s) end)
        |> Enum.map(fn {s, i} ->
          a = alerts[s]

          %{
            system_id: s,
            name: (Sde.system(s) || %{name: "#{s}"}).name,
            jumps_away: i,
            type: a.classification.type,
            description: a.classification.description
          }
        end)

      new =
        Enum.reject(threats, fn t -> Enum.any?(state.threats, &(&1.system_id == t.system_id)) end)

      evasive = if threats != [], do: evasive(state, path, alerts)

      for t <- new do
        message = "Amenaza en la ruta: #{t.description} (a #{t.jumps_away} saltos)"
        Events.emit(:warning, "Viajes", message)
        Tracking.broadcast(run, {:alert, message})
      end

      %{state | threats: threats, evasive: evasive}
    else
      state
    end
  end

  # Camino que falta: hasta el origen y después al destino, o directo al destino si ya compró.
  defp remaining_path(%{run: run, location: location}) do
    plan = run.plan
    mode = if plan["route_mode"] == "secure", do: :secure, else: :shortest
    here = (location && location[:solar_system_id]) || plan["origin_system_id"]
    dest = plan["destination_system_id"]

    if run.status in ["planned", "to_origin"] do
      to_origin = Routing.matrix_path(here, plan["origin_system_id"], mode) || [here]
      rest = Routing.matrix_path(plan["origin_system_id"], dest, mode) || []
      to_origin ++ Enum.drop(rest, 1)
    else
      Routing.matrix_path(here, dest, mode) || []
    end
  end

  # Solo con la carga comprada: antes, el piloto puede elegir otro trade.
  defp evasive(%{run: run}, path, alerts) do
    here = hd(path ++ [nil])
    dest = run.plan["destination_system_id"]
    threat = fn s -> (alerts[s] && alerts[s].threat) || 0.0 end

    with true <- here != nil and run.status not in ["planned", "to_origin"],
         [_ | _] = route <- Routing.evasive_path(here, dest, :shortest, threat),
         true <- route != path do
      %{
        path: route,
        extra_jumps: length(route) - length(path),
        # Cada sistema del desvío y la estación de venta al final.
        waypoints: Enum.drop(route, 1) ++ [run.plan["destination_location_id"]]
      }
    else
      _ -> nil
    end
  end

  ## Transacciones y cierre (RF-7.5)

  defp fetch_transactions(character_id, etag) do
    with {:ok, token} <- Sessions.token(character_id),
         {:ok, resp} <- Esi.character_wallet_transactions(character_id, token, etag) do
      if resp.status == 200, do: Tracking.store_transactions(character_id, resp.body || [])
      {:ok, resp.etag, resp.expires}
    end
  end

  defp reconcile(%{run: %{status: "closed"} = run} = state) do
    grace_min = GameRules.get(:run).reconcile_grace_min
    from = DateTime.add(run.started_at, -300, :second)
    to = DateTime.add(run.closed_at, grace_min * 60, :second)
    result = Reconcile.run(run.plan, Tracking.transactions(run.character_id, from, to))
    expired? = DateTime.compare(Clock.utc_now(), to) == :gt

    if result.complete or expired? do
      run = Tracking.put_result(run, result)

      Events.emit(
        :info,
        "Viajes",
        "#{run.plan["type_name"]}: P&L real #{round(result.profit / 1.0e6)}M (proyectado #{round(run.plan["profit"] / 1.0e6)}M)"
      )

      {:stop, :normal, %{state | run: run}}
    else
      {:noreply, state}
    end
  end

  defp reconcile(state), do: {:noreply, state}

  defp location(location_id, system_id) do
    %{
      location_id: location_id,
      system_id: system_id,
      region_id: (Sde.system(system_id) || %{})[:region_id]
    }
  end
end
