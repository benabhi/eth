defmodule EthWeb.ControlLive do
  @moduledoc """
  Centro de control: consola de operaciones del sistema (ERS §9.6, RF-8.10).

  - Barra de salud global siempre visible: Tranquility, error limit, pausa global de ESI,
    memoria, datos estáticos, cola de historial y próximo downtime.
  - Pestañas con URL propia (`/control/<pestaña>`):
    - **Resumen:** lo que requiere atención y los instrumentos de cada proceso (§9.10):
      pollers de los hubs como anillos dobles, la evaluación del motor como barra
      segmentada, los presupuestos de ESI como arcos, la cola de historial como medidor
      de caudal, el feed del radar como pulso y el SDE como secuencia de pasos.
    - **Mercado:** regiones por nivel (mosaicos) o en el mapa del universo, con su detalle
      y acciones (RF-8.2, RF-8.3). El mapa (`?view=map`) ubica cada región según el SDE con
      el estado de su poller y el calor del radar; al elegir una, muestra sus sistemas con
      la seguridad y las kills de cada uno (capas: pollers, radar o ambos).
    - **Radar:** feed, sistemas calientes y últimas kills relevantes (RF-8.5).
    - **Personajes:** sesiones y tokens, con un anillo por recurso (RF-8.6).
    - **Registros:** eventos del sistema filtrables (RF-8.7).
    - **ESI:** presupuestos por grupo y error limit (RF-8.8).

  Se actualiza por PubSub; un tick por segundo refresca las cuentas regresivas.

  Implementa: RF-1.12, RF-3.8, RF-8.1, RF-8.2, RF-8.3, RF-8.5, RF-8.6, RF-8.7, RF-8.8,
  RF-8.9, RF-8.10, RF-11.2.
  """
  use EthWeb, :live_view

  import EthWeb.TradingComponents, only: [row_detail: 1, detail_col: 1]

  alias Eth.Characters.Sessions
  alias Eth.{Clock, Engine, Events, Market, Metrics, Sde, Threat}
  alias Eth.Esi.{Budget, ServerStatus}
  alias EthWeb.{Format, GalaxyMap}

  @event_limit 60
  @radar_hot 15
  @radar_kills 40
  @tiers [hub: "N1 · Hubs", active: "N2 · Activas", rest: "N3 · Resto"]
  @tab_keys ~w(overview market radar characters logs esi)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Eth.PubSub, Market.status_topic())
      Phoenix.PubSub.subscribe(Eth.PubSub, Events.topic())
      Phoenix.PubSub.subscribe(Eth.PubSub, ServerStatus.topic())
      Phoenix.PubSub.subscribe(Eth.PubSub, Sde.topic())
      Phoenix.PubSub.subscribe(Eth.PubSub, Threat.kills_topic())
      schedule_tick()
    end

    socket =
      socket
      |> assign(:page_title, gettext("Centro de control"))
      |> assign(:regions, Map.new(Market.region_statuses(), &{&1.region_id, &1}))
      |> assign(:selected, nil)
      |> assign(:region_map, nil)
      |> assign(:market_view, "tiles")
      |> assign(:map_layer, :both)
      |> assign(:galaxy, Sde.galaxy())
      |> assign(:event_level, nil)
      |> assign(:events, Events.recent(@event_limit))
      |> assign(:tiers, @tiers)
      |> assign(:dev_routes, Application.get_env(:eth, :dev_routes, false))
      |> assign(:sde, Sde.status())
      |> assign(:sessions, Sessions.list())
      |> assign(:kills, Enum.take(Threat.recent_kills(), @radar_kills))
      |> refresh_health()
      |> refresh_radar()

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case Map.get(params, "tab", "overview") do
      tab when tab in @tab_keys ->
        {:noreply,
         socket
         |> assign(:tab, tab)
         |> assign(:market_view, if(params["view"] == "map", do: "map", else: "tiles"))
         |> assign_selected(selected_region(params, socket.assigns.selected))}

      _unknown ->
        {:noreply, push_patch(socket, to: ~p"/control")}
    end
  end

  # `?region=<id>` (desde un anillo del Resumen) abre el detalle de esa región.
  defp selected_region(%{"region" => id}, current) do
    case Integer.parse(id) do
      {region_id, ""} -> region_id
      _ -> current
    end
  end

  defp selected_region(_params, current), do: current

  ## Mensajes

  @impl true
  def handle_info({:region_status, status}, socket) do
    {:noreply, update(socket, :regions, &Map.put(&1, status.region_id, status))}
  end

  def handle_info({:system_event, event}, socket) do
    if socket.assigns.event_level in [nil, event.level] do
      {:noreply, update(socket, :events, &Enum.take([event | &1], @event_limit))}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:server_status, _status}, socket), do: {:noreply, refresh_health(socket)}

  # Radar (RF-8.5): kills relevantes en vivo; `EthWeb.RadarHook` ya maneja la cabecera.
  def handle_info({:kill, kill}, socket),
    do: {:noreply, update(socket, :kills, &Enum.take([kill | &1], @radar_kills))}

  def handle_info({:heatmap, _version}, socket), do: {:noreply, refresh_radar(socket)}
  # Con el SDE listo (o recargado) se rehace la geometría del mapa (RF-8.2).
  def handle_info({:sde_status, %{state: :ready} = status}, socket) do
    {:noreply,
     socket
     |> assign(sde: status, galaxy: Sde.galaxy())
     |> assign_selected(socket.assigns.selected)}
  end

  def handle_info({:sde_status, status}, socket), do: {:noreply, assign(socket, :sde, status)}
  def handle_info({:esi_paused, _until, _reason}, socket), do: {:noreply, refresh_health(socket)}
  def handle_info(:esi_resumed, socket), do: {:noreply, refresh_health(socket)}

  # El piloto lo actualiza `EthWeb.PilotHook`; las sesiones se refrescan con el tick.
  def handle_info({:character, _id, _event, _public}, socket), do: {:noreply, socket}

  def handle_info(:tick, socket) do
    schedule_tick()

    {:noreply,
     socket |> assign(:sessions, Sessions.list()) |> refresh_health() |> refresh_radar()}
  end

  ## Eventos de la UI

  @impl true
  # Clic en una región: abre su detalle bajo el nivel, o lo cierra si ya estaba abierto.
  def handle_event("select_region", %{"id" => id}, socket) do
    id = String.to_integer(id)
    selected = if socket.assigns.selected == id, do: nil, else: id
    {:noreply, assign_selected(socket, selected)}
  end

  def handle_event("close_detail", _params, socket),
    do: {:noreply, assign_selected(socket, nil)}

  # Capas del mapa (RF-8.2): estado de los pollers, calor del radar o ambos.
  def handle_event("map_layer", %{"layer" => layer}, socket) do
    layer = Enum.find([:pollers, :radar, :both], :both, &(Atom.to_string(&1) == layer))
    {:noreply, assign(socket, :map_layer, layer)}
  end

  def handle_event("refresh_now", %{"id" => id}, socket) do
    case Market.refresh_now(String.to_integer(id)) do
      :ok ->
        {:noreply, put_flash(socket, :info, gettext("Actualización solicitada"))}

      {:error, :not_expired} ->
        {:noreply,
         put_flash(socket, :error, gettext("ESI todavía no tiene datos nuevos para esta región"))}

      {:error, :busy} ->
        {:noreply, put_flash(socket, :error, gettext("La región ya se está descargando"))}

      {:error, :paused} ->
        {:noreply,
         put_flash(socket, :error, gettext("La región está en pausa: reanudala primero"))}
    end
  end

  def handle_event("pause_region", %{"id" => id}, socket) do
    :ok = Market.pause(String.to_integer(id))
    {:noreply, socket}
  end

  def handle_event("resume_region", %{"id" => id}, socket) do
    :ok = Market.resume(String.to_integer(id))
    {:noreply, socket}
  end

  def handle_event("pause_esi", _params, socket) do
    Budget.pause_all(DateTime.add(Clock.utc_now(), 365, :day), :manual)
    Events.emit(:action, "Usuario", "Pausa global de ESI")
    {:noreply, refresh_health(socket)}
  end

  def handle_event("resume_esi", _params, socket) do
    Budget.resume_all()
    Events.emit(:action, "Usuario", "Reanudación global de ESI")
    {:noreply, refresh_health(socket)}
  end

  def handle_event("filter_events", %{"level" => level}, socket) do
    level = if level == "", do: nil, else: level
    filters = if level, do: [level: level], else: []

    {:noreply,
     socket
     |> assign(:event_level, level)
     |> assign(:events, Events.recent(@event_limit, filters))}
  end

  ## Pestañas y atención (RF-8.10)

  defp control_tabs(assigns) do
    attention = attention(assigns)

    [
      {"overview", gettext("Resumen"), ~p"/control", length(attention)},
      {"market", gettext("Mercado"), ~p"/control/market",
       Enum.count(attention, &(elem(&1, 0) == :region))},
      {"radar", gettext("Radar"), ~p"/control/radar", if(assigns.radar_degraded, do: 1, else: 0)},
      {"characters", gettext("Personajes"), ~p"/control/characters",
       Enum.count(attention, &(elem(&1, 0) == :session))},
      {"logs", gettext("Registros"), ~p"/control/logs"},
      {"esi", gettext("ESI"), ~p"/control/esi", if(assigns.budget.paused_until, do: 1, else: 0)}
    ]
  end

  # Lo que requiere atención ahora: {tipo, texto, ruta}.
  defp attention(assigns) do
    # Agrupadas por estado: con muchas regiones (el primer escaneo del universo) un solo
    # aviso por estado en lugar de uno por región.
    regions =
      for status <- Map.values(assigns.regions),
          {key, label, _color} = display(status, assigns.now),
          key in [:backoff, :excluded, :stale, :degraded] do
        {label, status}
      end
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.map(fn
        {label, [status]} ->
          {:region, "#{status.name}: #{label}", ~p"/control/market?region=#{status.region_id}"}

        {label, statuses} ->
          {:region,
           ngettext(
             "%{count} región · %{label}",
             "%{count} regiones · %{label}",
             length(statuses),
             label: String.downcase(label)
           ), ~p"/control/market"}
      end)

    sessions =
      for s <- assigns.sessions, s.status in [:relogin, :token_error] do
        {:session, "#{s.name}: #{session_label(s.status)}", ~p"/control/characters"}
      end

    esi =
      if assigns.budget.paused_until,
        do: [{:esi, gettext("ESI en pausa"), ~p"/control/esi"}],
        else: []

    radar =
      if assigns.radar_degraded,
        do: [{:radar, gettext("Radar degradado: solo línea base"), ~p"/control/radar"}],
        else: []

    sde =
      if assigns.sde[:state] == :error,
        do: [{:sde, gettext("Datos estáticos con error"), ~p"/control"}],
        else: []

    Enum.sort_by(regions, &elem(&1, 1)) ++ esi ++ radar ++ sde ++ sessions
  end

  ## Instrumentos (§9.10)

  # Anillo exterior del poller: tiempo que falta hasta `Expires`, sobre la ventana de caché.
  defp expires_fraction(%{expires: %DateTime{} = exp, last_modified: %DateTime{} = lm}, now) do
    window = max(DateTime.diff(exp, lm), 1)
    min(max(DateTime.diff(exp, now) / window, 0.0), 1.0)
  end

  defp expires_fraction(_status, _now), do: 0.0

  @doc false
  # Anillo interior: páginas del ciclo en curso (o completo si está en reposo). Al empezar
  # una descarga, antes de saber el total, va vacío: mostrar las páginas del ciclo anterior
  # lo dejaba lleno en "Iniciando…" y después caía de golpe.
  @spec pages_fraction(map()) :: float()
  def pages_fraction(%{progress: {done, total}}) when is_integer(total) and total > 0,
    do: done / total

  def pages_fraction(%{status: :fetching}), do: 0.0
  def pages_fraction(%{pages: pages}) when is_integer(pages) and pages > 0, do: 1.0
  def pages_fraction(_status), do: 0.0

  # Etapas de la última evaluación del motor: [{etiqueta, ms, clase}].
  defp engine_stages(meta) do
    [
      {gettext("resúmenes"), meta[:summaries_ms], "bg-info"},
      {gettext("directo"), meta[:direct_ms], "bg-primary"},
      {gettext("estación"), meta[:station_ms], "bg-secondary"},
      {gettext("por órdenes"), meta[:orders_ms], "bg-accent"}
    ]
    |> Enum.filter(fn {_label, ms, _class} -> is_integer(ms) end)
    |> with_remainder(meta.duration_ms)
  end

  # Lo que no cae en ninguna etapa (sobre todo la demanda de historial) completa la barra.
  defp with_remainder([], _total), do: []

  defp with_remainder(stages, total) do
    rest = total - Enum.sum_by(stages, &elem(&1, 1))

    if rest > 0,
      do: stages ++ [{gettext("historial y resto"), rest, "bg-base-content/40"}],
      else: stages
  end

  defp stage_width(ms, meta), do: Float.round(max(ms, 0) * 100 / max(meta.duration_ms, 1), 1)

  # Presupuestos por grupo de ESI, los más usados primero.
  defp budget_groups(budget) do
    budget.groups
    |> Enum.map(fn {{name, character_id}, state} ->
      %{
        name: name,
        character_id: character_id,
        limit: state[:limit],
        remaining: state[:remaining],
        at: state[:at],
        used: used_fraction(state)
      }
    end)
    |> Enum.sort_by(&{-&1.used, &1.name})
  end

  defp used_fraction(%{limit: limit, remaining: remaining})
       when is_integer(limit) and limit > 0 and is_integer(remaining),
       do: (limit - remaining) / limit

  defp used_fraction(_state), do: 0.0

  defp used_class(used) when used >= 0.9, do: "text-error"
  defp used_class(used) when used >= 0.7, do: "text-warning"
  defp used_class(_used), do: "text-primary"

  # Error limit: fracción de errores ya consumidos en la ventana (100 por minuto).
  defp error_used(%{error_limit: %{remain: remain}}), do: (100 - remain) / 100
  defp error_used(_budget), do: 0.0

  # Minutos estimados para vaciar la cola de historial al ritmo máximo.
  defp drain_minutes(%{pending: pending, max_per_min: max}) when max > 0,
    do: Float.ceil(pending / max) |> trunc()

  defp drain_minutes(_history), do: 0

  defp sde_steps(sde) do
    order = [:downloading, :processing, :ready]
    labels = [gettext("Descarga"), gettext("Proceso y grafo"), gettext("Listo")]

    current =
      case sde[:state] do
        :error -> -1
        state -> Enum.find_index(order, &(&1 == state)) || 0
      end

    labels
    |> Enum.with_index()
    |> Enum.map(fn {label, i} ->
      cond do
        current == 2 or i < current -> {label, :done}
        i == current -> {label, :current}
        true -> {label, :pending}
      end
    end)
  end

  # Frescura de un recurso de la sesión: cuánto pasó desde la última lectura sobre el
  # intervalo hasta la próxima consulta (el anillo se llena hasta la próxima lectura).
  defp resource_fraction(session, resource, now) do
    read = session.read_at[resource]
    next = session.next_at[resource]

    if read && next do
      span = max(DateTime.diff(next, read), 1)
      min(max(DateTime.diff(now, read) / span, 0.0), 1.0)
    else
      0.0
    end
  end

  ## Datos derivados

  defp schedule_tick, do: Process.send_after(self(), :tick, 1_000)

  defp refresh_radar(socket) do
    hot = Threat.hot_systems()

    assign(socket,
      feed: Threat.feed_status(),
      baseline: Threat.baseline_meta(),
      hot: Enum.take(hot, @radar_hot),
      # Calor del radar para el mapa (RF-8.2): por región y por sistema.
      heat: GalaxyMap.region_heat(hot, &system_region/1),
      system_heat: Map.new(hot, &{&1.system_id, GalaxyMap.system_heat(&1)})
    )
  end

  defp system_region(system_id) do
    case Sde.system(system_id) do
      %{region_id: region_id} -> region_id
      nil -> nil
    end
  end

  # Región elegida (detalle y, en el mapa, sus sistemas).
  defp assign_selected(socket, nil), do: assign(socket, selected: nil, region_map: nil)

  defp assign_selected(socket, region_id),
    do: assign(socket, selected: region_id, region_map: Sde.region_map(region_id))

  defp feed_label(%{source: :off}), do: gettext("Feed apagado (ETH_KILLFEED=off)")

  defp feed_label(%{source: :replay} = f),
    do: gettext("Replay · %{n} kills grabadas", n: f.recorded)

  defp feed_label(%{status: :live}), do: gettext("R2Z2 · en vivo")
  defp feed_label(%{status: :waiting}), do: gettext("R2Z2 · al día, esperando kills")
  defp feed_label(%{status: :banned}), do: gettext("R2Z2 · bloqueado (403): pausa de 1 h")
  defp feed_label(%{status: :error}), do: gettext("R2Z2 · con errores, reintentando")
  defp feed_label(_feed), do: gettext("R2Z2 · conectando")

  defp threat_type_label(:gate_camp), do: gettext("Gatecamp")
  defp threat_type_label(:bubble_camp), do: gettext("Bubble camp")
  defp threat_type_label(:smartbomb_camp), do: gettext("Smartbombs")
  defp threat_type_label(:hauler_gank), do: gettext("Gank de transportes")
  defp threat_type_label(_roaming), do: gettext("Actividad hostil")

  # Cuántas veces más kills que lo esperado por la línea base.
  defp over_normal(%{kills: kills, lambda: lambda}),
    do: :erlang.float_to_binary(kills / max(lambda, 0.01), decimals: 0)

  # Tendencia de un sistema caliente (RF-8.5): sube en rojo, baja en verde.
  defp trend_class(:rising), do: "text-error"
  defp trend_class(:falling), do: "text-success"
  defp trend_class(_steady), do: "text-base-content/40"

  defp trend_label(:rising), do: gettext("En aumento: más kills en los últimos minutos")
  defp trend_label(:falling), do: gettext("En baja: menos kills en los últimos minutos")
  defp trend_label(_steady), do: gettext("Estable")

  # Alto de cada barra (en un viewBox de 12): al menos 1 para que se vea el tramo vacío.
  defp bar_height(n, buckets), do: max(round(n / max(Enum.max(buckets), 1) * 12), 1)

  defp system_name(id), do: (Sde.system(id) || %{name: "#{id}"}).name

  defp sec_style(system_id) do
    case Sde.system(system_id) do
      %{security: sec} -> "color: #{Sde.security_color(sec)}"
      nil -> ""
    end
  end

  defp sec_label(system_id) do
    case Sde.system(system_id) do
      %{security: sec} -> :erlang.float_to_binary(Sde.security_display(sec), decimals: 1)
      nil -> "?"
    end
  end

  defp refresh_health(socket) do
    now = Clock.utc_now()

    assign(socket,
      now: now,
      engine_meta: Engine.meta(),
      server: ServerStatus.current(),
      budget: Budget.snapshot(),
      market_budget: Budget.group(Eth.GameRules.get(:market_budget_group)),
      history: Market.history_status(),
      memory: %{total: :erlang.memory(:total), ets: :erlang.memory(:ets)},
      next_downtime: ServerStatus.next_downtime(now),
      metrics: Metrics.series(),
      viewers: Metrics.viewers()
    )
  end

  # Etapas del pipeline (RF-8.4). `flowing` dice si pasan datos hacia esa etapa: consultas
  # en el último minuto, una evaluación reciente, pantallas conectadas.
  defp pipeline_stages(assigns) do
    meta = assigns.engine_meta
    requests = assigns.metrics.requests |> Enum.at(-2, 0)
    fresh_engine? = meta != nil and DateTime.diff(assigns.now, meta.evaluated_at) < 60
    t = totals(assigns.regions)

    [
      %{
        id: "esi",
        title: "ESI",
        value: gettext("%{n} consultas/s", n: Float.round(requests / 60, 1)),
        detail: gettext("pedidos a los servidores de EVE"),
        flowing: false
      },
      %{
        id: "snapshots",
        title: gettext("Mercados en memoria"),
        value: gettext("%{fresh}/%{count} regiones al día", fresh: t.fresh, count: t.count),
        detail: gettext("%{orders} órdenes guardadas", orders: Format.compact(t.orders)),
        flowing: requests > 0
      },
      %{
        id: "engine",
        title: gettext("Motor"),
        value:
          if(meta,
            do: gettext("%{s} s por cálculo", s: Float.round(meta.duration_ms / 1000, 1)),
            else: "—"
          ),
        detail:
          if(meta,
            do: gettext("busca trades en todo el mercado"),
            else: gettext("todavía no calculó")
          ),
        flowing: fresh_engine?
      },
      %{
        id: "opportunities",
        title: gettext("Oportunidades"),
        value:
          if(meta, do: gettext("%{n} directas", n: Format.integer(meta.opportunities)), else: "—"),
        detail:
          if(meta,
            do:
              gettext("%{s} estación · %{o} órdenes",
                s: Format.compact(meta.station_candidates),
                o: Format.compact(meta.order_candidates)
              ),
            else: ""
          ),
        flowing: fresh_engine?
      },
      %{
        id: "viewers",
        title: gettext("Pestañas abiertas"),
        value: Format.integer(assigns.viewers),
        detail: gettext("de la app, se actualizan solas"),
        flowing: fresh_engine? and assigns.viewers > 0
      }
    ]
  end

  # Mosaicos de la última hora (RF-8.9): título, valor del último minuto con datos y serie.
  # Los contadores tienen un valor por minuto (0 si no hubo nada); las medidas (latencia,
  # duraciones, tokens) solo existen en los minutos con muestras, así que el gráfico
  # repite la última (`hold`) en vez de cortarse: el valor sigue siendo el vigente.
  defp metric_tiles(s) do
    [
      %{
        id: "requests",
        title: gettext("Consultas a EVE / min"),
        values: s.requests,
        value: last_complete(s.requests),
        class: "text-primary",
        hold: false
      },
      %{
        id: "errors",
        title: gettext("Errores / min"),
        values: s.errors,
        value: last_complete(s.errors),
        class: "text-error",
        hold: false
      },
      %{
        id: "latency",
        title: gettext("Latencia de EVE"),
        values: s.latency_ms,
        value: last(s.latency_ms, &"#{round(&1)} ms"),
        class: "text-info",
        hold: true
      },
      %{
        id: "evaluate",
        title: gettext("Evaluación del motor"),
        values: s.evaluate_ms,
        value: last(s.evaluate_ms, &"#{Float.round(&1 / 1000, 1)} s"),
        class: "text-accent",
        hold: true
      },
      %{
        id: "query",
        title: gettext("Consulta del tablón"),
        values: s.query_ms,
        value: last(s.query_ms, &"#{round(&1)} ms"),
        class: "text-secondary",
        hold: true
      },
      %{
        id: "tokens",
        title: gettext("Tokens de mercado"),
        values: s.market_tokens,
        value: last(s.market_tokens, &"#{round(&1 * 100)} %"),
        class: "text-success",
        hold: true
      }
    ]
  end

  # Contadores por minuto: el último minuto completo (el actual recién empieza).
  defp last_complete(values) when length(values) >= 2,
    do: values |> Enum.at(-2) |> Format.integer()

  defp last_complete(_values), do: "—"

  defp last(values, format) do
    case values |> Enum.reject(&is_nil/1) |> List.last() do
      nil -> "—"
      value -> format.(value)
    end
  end

  @doc false
  # Estado visual de un mosaico: {clave, etiqueta, clase de color}. Prioriza lo que el
  # poller está haciendo; si está en reposo, muestra la frescura de sus datos.
  @spec display(map(), DateTime.t()) :: {atom(), String.t(), String.t()}
  def display(%{status: :fetching}, _now), do: {:fetching, gettext("Descargando"), "info"}
  def display(%{status: :backoff}, _now), do: {:backoff, gettext("Error"), "error"}

  def display(%{status: :rate_limited}, _now),
    do: {:rate_limited, gettext("Limitado"), "secondary"}

  def display(%{status: :paused, pause_reason: :downtime}, _now),
    do: {:paused, gettext("Downtime"), "neutral"}

  def display(%{status: :paused}, _now), do: {:paused, gettext("Pausado"), "neutral"}

  def display(status, now) do
    case Market.freshness(status.last_modified, status.expires, now) do
      :none -> {:none, gettext("Sin datos"), "neutral"}
      :fresh -> fresh_label(status)
      :degraded -> {:degraded, gettext("Degradado"), "warning"}
      :stale -> {:stale, gettext("Viejo"), "warning"}
      :excluded -> {:excluded, gettext("Excluido"), "error"}
    end
  end

  defp fresh_label(%{replay: true}), do: {:fresh, gettext("Replay"), "success"}
  defp fresh_label(%{restored: true}), do: {:fresh, gettext("Restaurado"), "success"}
  defp fresh_label(_status), do: {:fresh, gettext("Cacheado"), "success"}

  # Texto secundario del mosaico según el estado.
  defp timing(%{status: :fetching, progress: {done, total}}, _now) when is_integer(total),
    do: gettext("Pág %{done}/%{total}", done: done, total: total)

  defp timing(%{status: :fetching}, _now), do: gettext("Iniciando…")
  defp timing(%{status: :backoff, next_at: at}, now), do: "reint. " <> Format.countdown(at, now)

  defp timing(%{status: :rate_limited, next_at: at}, now),
    do: "espera " <> Format.countdown(at, now)

  defp timing(%{status: :paused, pause_reason: :manual}, _now), do: gettext("manual")
  defp timing(%{next_at: at}, now), do: "T-" <> Format.countdown(at, now)

  # Mosaicos de un nivel ya con su estado visual calculado.
  defp tiles(regions, tier, now) do
    for status <- regions_in_tier(regions, tier), do: {status, display(status, now)}
  end

  # Clases literales (Tailwind solo incluye clases que aparecen completas en el código).
  defp tone_border("success"), do: "border-l-success"
  defp tone_border("info"), do: "border-l-info"
  defp tone_border("error"), do: "border-l-error"
  defp tone_border("warning"), do: "border-l-warning"
  defp tone_border("secondary"), do: "border-l-secondary"
  defp tone_border(_neutral), do: "border-l-base-content/30"

  defp tone_text("success"), do: "text-success"
  defp tone_text("info"), do: "text-info"
  defp tone_text("error"), do: "text-error"
  defp tone_text("warning"), do: "text-warning"
  defp tone_text("secondary"), do: "text-secondary"
  defp tone_text(_neutral), do: "text-base-content/70"

  defp tier_label(:hub), do: gettext("N1 · Hub")
  defp tier_label(:active), do: gettext("N2 · Activa")
  defp tier_label(_rest), do: gettext("N3 · Resto")

  defp regions_in_tier(regions, tier) do
    regions
    |> Map.values()
    |> Enum.filter(&(&1.tier == tier))
    |> Enum.sort_by(& &1.name)
  end

  defp totals(regions) do
    values = Map.values(regions)

    %{
      count: length(values),
      fresh:
        Enum.count(
          values,
          &(&1.status != :fetching and display(&1, Clock.utc_now()) |> elem(0) == :fresh)
        ),
      orders: values |> Enum.map(&(&1.orders || 0)) |> Enum.sum(),
      bytes: values |> Enum.map(&(&1.bytes || 0)) |> Enum.sum()
    }
  end

  defp sde_label(%{state: :ready}), do: {gettext("Listo"), "text-success"}
  defp sde_label(%{state: :downloading}), do: {gettext("Descargando"), "text-info"}
  defp sde_label(%{state: :processing}), do: {gettext("Procesando"), "text-info"}
  defp sde_label(%{state: :error}), do: {gettext("Error"), "text-error"}
  defp sde_label(%{state: :stopped}), do: {gettext("Detenido"), "eth-muted"}
  defp sde_label(_loading), do: {gettext("Cargando"), "eth-muted"}

  defp level_badge("error"), do: {"ERROR", "border-error/70 text-error"}
  defp level_badge("warning"), do: {"AVISO", "border-warning/70 text-warning"}
  defp level_badge("action"), do: {"ACCIÓN", "border-secondary/70 text-secondary"}
  defp level_badge(_level), do: {"INFO", "border-base-content/30 eth-muted"}

  # Sparkline SVG de duraciones de los últimos ciclos (más viejo a la izquierda).
  defp sparkline_points(history) do
    values = history |> Enum.reverse() |> Enum.map(& &1.duration_ms)

    case values do
      [] ->
        ""

      [_single] ->
        "0,10 100,10"

      _ ->
        max = Enum.max(values)
        step = 100 / (length(values) - 1)

        values
        |> Enum.with_index()
        |> Enum.map_join(" ", fn {v, i} ->
          "#{Float.round(i * step, 1)},#{Float.round(20 - v / max(max, 1) * 18, 1)}"
        end)
    end
  end

  ## Detalle de una región (RF-8.3): el mismo en los mosaicos y en el mapa

  attr :r, :map, required: true, doc: "estado público del poller"
  attr :now, :any, required: true

  defp region_detail(assigns) do
    ~H"""
    <% r = @r %>
    <% {_key, label, color} = display(r, @now) %>
    <.row_detail id="region-detail" label={gettext("Detalle de %{name}", name: r.name)}>
      <div class="flex items-center gap-4">
        <.double_ring
          outer={expires_fraction(r, @now)}
          inner={pages_fraction(r)}
          size={88}
          outer_class={tone_text(color)}
          label={label}
        >
          <span class="font-mono text-xs eth-strong">{timing(r, @now)}</span>
        </.double_ring>
        <div class="min-w-0">
          <h2 id="detail-title" class="font-display text-lg font-semibold eth-strong">
            {r.name}
          </h2>
          <div class={["text-sm", tone_text(color)]}>{label}</div>
          <div class="font-mono text-xs eth-faint">
            {r.region_id} · {tier_label(r.tier)} ·
            <.term name={:generation}>{gettext("gen.")}</.term>
            {r.generation || "—"}
          </div>
        </div>
      </div>

      <.detail_col title={gettext("Caché de ESI")} topic={:pollers}>
        <dl class="grid grid-cols-[auto_1fr] gap-x-3 gap-y-0.5 text-sm">
          <dt class="eth-muted">Last-Modified</dt>
          <dd class="text-right font-mono">
            {Format.eve_time(r.last_modified)}
            <span class="eth-faint">({Format.ago(r.last_modified, @now)})</span>
          </dd>
          <dt class="eth-muted">Expires</dt>
          <dd class="text-right font-mono">
            {Format.eve_time(r.expires)}
            <span class="eth-faint">(T-{Format.countdown(r.expires, @now)})</span>
          </dd>
          <dt class="eth-muted">{gettext("Próximo ciclo")}</dt>
          <dd class="text-right font-mono">{Format.eve_time(r.next_at)}</dd>
          <dt class="eth-muted">{gettext("Páginas")}</dt>
          <dd class="text-right font-mono">
            {r.pages || "—"} ({r.not_modified_pages || 0} × 304)
          </dd>
          <dt class="eth-muted">{gettext("Estado interno")}</dt>
          <dd class="text-right font-mono eth-faint">{r.status}</dd>
        </dl>
      </.detail_col>

      <.detail_col title={gettext("Órdenes en memoria")}>
        <dl class="grid grid-cols-[auto_1fr] gap-x-3 gap-y-0.5 text-sm">
          <dt class="eth-muted">{gettext("Total")}</dt>
          <dd class="text-right font-mono eth-strong">{Format.integer(r.orders)}</dd>
          <dt class="eth-muted">{gettext("Venta")}</dt>
          <dd class="text-right font-mono">{Format.compact(r.sell_orders)}</dd>
          <dt class="eth-muted">{gettext("Compra")}</dt>
          <dd class="text-right font-mono">{Format.compact(r.buy_orders)}</dd>
          <dt class="eth-muted">{gettext("Memoria ETS")}</dt>
          <dd class="text-right font-mono">{Format.bytes(r.bytes)}</dd>
          <dt class="eth-muted">{gettext("Fallos seguidos")}</dt>
          <dd class={["text-right font-mono", r.failures > 0 && "text-warning"]}>
            {r.failures}
          </dd>
        </dl>
        <p :if={r.last_error} class="mt-2 text-xs text-error">{r.last_error}</p>
      </.detail_col>

      <.detail_col title={gettext("Duración de los ciclos")}>
        <%= if r.history != [] do %>
          <svg viewBox="0 0 100 20" class="h-12 w-full text-primary" aria-hidden="true">
            <polyline
              fill="none"
              stroke="currentColor"
              stroke-width="1.5"
              vector-effect="non-scaling-stroke"
              points={sparkline_points(r.history)}
            />
          </svg>
          <p class="mt-1 text-xs eth-faint">
            {gettext("Últimos %{n} ciclos", n: length(r.history))} · {gettext("último")}: {Format.duration(
              div(hd(r.history).duration_ms, 1000)
            )}
          </p>
        <% else %>
          <p class="text-xs eth-faint">{gettext("Todavía sin ciclos completos.")}</p>
        <% end %>
      </.detail_col>

      <:footer>
        <button
          phx-click="refresh_now"
          phx-value-id={r.region_id}
          class="btn btn-primary btn-sm"
        >
          <.icon name="hero-arrow-path" class="size-4" /> {gettext("Actualizar ahora")}
        </button>
        <button
          :if={r.status != :paused or r.pause_reason != :manual}
          phx-click="pause_region"
          phx-value-id={r.region_id}
          class="btn btn-outline btn-sm"
        >
          <.icon name="hero-pause" class="size-4" /> {gettext("Pausar")}
        </button>
        <button
          :if={r.status == :paused and r.pause_reason == :manual}
          phx-click="resume_region"
          phx-value-id={r.region_id}
          class="btn btn-outline btn-sm"
        >
          <.icon name="hero-play" class="size-4" /> {gettext("Reanudar región")}
        </button>
        <span class="text-xs eth-faint">
          {gettext(
            "\"Actualizar ahora\" solo actúa si ESI ya publicó datos nuevos o si la región está en error."
          )}
        </span>
        <button
          type="button"
          phx-click="close_detail"
          class="btn btn-ghost btn-sm ml-auto eth-muted"
        >
          <.icon name="hero-chevron-up" class="size-4" /> {gettext("Cerrar")}
          <kbd class="kbd kbd-xs">Esc</kbd>
        </button>
      </:footer>
    </.row_detail>
    """
  end

  ## Mapa del universo (RF-8.2)

  attr :map, :map, required: true, doc: "`Eth.Sde.galaxy/0`"
  attr :regions, :map, required: true
  attr :heat, :map, required: true
  attr :layer, :atom, required: true
  attr :selected, :integer, default: nil
  attr :now, :any, required: true

  defp galaxy_map(assigns) do
    max_orders =
      assigns.regions |> Map.values() |> Enum.map(&(&1.orders || 0)) |> Enum.max(fn -> 1 end)

    assigns =
      assign(assigns,
        points: Map.new(assigns.map.nodes, &{&1.id, &1}),
        max_orders: max(max_orders, 1)
      )

    ~H"""
    <svg
      id="galaxy-map"
      viewBox={"0 0 #{@map.width} #{@map.height}"}
      class="h-auto w-full"
      role="group"
      aria-label={gettext("Mapa de regiones")}
    >
      <g aria-hidden="true" class="text-base-content/15">
        <line
          :for={{a, b} <- @map.links}
          x1={@points[a].x}
          y1={@points[a].y}
          x2={@points[b].x}
          y2={@points[b].y}
          stroke="currentColor"
          stroke-width="1"
          vector-effect="non-scaling-stroke"
        />
      </g>
      <.map_region
        :for={n <- @map.nodes}
        node={n}
        status={@regions[n.id]}
        heat={@heat[n.id]}
        layer={@layer}
        selected={@selected == n.id}
        max_orders={@max_orders}
        now={@now}
      />
    </svg>
    """
  end

  attr :node, :map, required: true
  attr :status, :map, default: nil, doc: "estado del poller (`nil` si la región no se sigue)"
  attr :heat, :map, default: nil
  attr :layer, :atom, required: true
  attr :selected, :boolean, default: false
  attr :max_orders, :integer, required: true
  attr :now, :any, required: true

  # Una región: anillo con el estado y la cuenta regresiva de su poller, tamaño según sus
  # órdenes y halo rojo con el calor del radar.
  defp map_region(assigns) do
    %{status: status, heat: heat, layer: layer, now: now} = assigns

    {_key, label, color} =
      if status, do: display(status, now), else: {:none, gettext("Sin poller"), "neutral"}

    r = if status, do: GalaxyMap.node_radius(status.orders, assigns.max_orders), else: 3.5
    radar? = layer in [:radar, :both]
    alerts? = radar? and heat != nil and heat.alerts > 0

    assigns =
      assign(assigns,
        r: r,
        label: label,
        color: color,
        pollers?: status != nil and layer in [:pollers, :both],
        halo: radar? && GalaxyMap.halo_radius(heat, r),
        alerts?: alerts?,
        fraction: status && map_fraction(status, now),
        named?: (status != nil and status.tier == :hub) or assigns.selected or alerts?
      )

    ~H"""
    <g
      id={"map-region-#{@node.id}"}
      class="cursor-pointer outline-none"
      role="button"
      tabindex="0"
      phx-click="select_region"
      phx-keydown="select_region"
      phx-key="Enter"
      phx-value-id={@node.id}
      aria-label={"#{@node.name}: #{@label}"}
      aria-pressed={to_string(@selected)}
    >
      <title>{region_title(@node, @status, @label, @heat)}</title>
      <circle
        :if={@halo}
        cx={@node.x}
        cy={@node.y}
        r={@halo}
        class={["fill-error", @alerts? && "eth-pulse-bar"]}
        fill-opacity={if(@alerts?, do: "0.3", else: "0.12")}
      />
      <%= if @pollers? do %>
        <circle
          cx={@node.x}
          cy={@node.y}
          r={@r}
          class={["fill-base-100", tone_text(@color)]}
          stroke="currentColor"
          stroke-opacity="0.3"
          stroke-width="2"
          vector-effect="non-scaling-stroke"
        />
        <circle
          cx={@node.x}
          cy={@node.y}
          r={@r}
          fill="none"
          stroke="currentColor"
          class={tone_text(@color)}
          stroke-width="2.5"
          stroke-dasharray={GalaxyMap.arc_dash(@fraction, @r)}
          transform={"rotate(-90 #{@node.x} #{@node.y})"}
        />
        <circle cx={@node.x} cy={@node.y} r="2.5" fill="currentColor" class={tone_text(@color)} />
      <% else %>
        <circle
          cx={@node.x}
          cy={@node.y}
          r={if(@status, do: 4, else: 3)}
          class={if(@status, do: "fill-base-content/50", else: "fill-base-content/25")}
        />
      <% end %>
      <circle
        :if={@selected}
        cx={@node.x}
        cy={@node.y}
        r={@r + 5}
        fill="none"
        stroke="currentColor"
        class="text-primary"
        stroke-width="1.5"
        vector-effect="non-scaling-stroke"
      />
      <text
        :if={@named?}
        x={@node.x}
        y={@node.y + @r + 14}
        text-anchor="middle"
        class={[
          "font-display text-[12px]",
          if(@selected, do: "fill-primary", else: "fill-base-content/80")
        ]}
      >
        {@node.name}
      </text>
    </g>
    """
  end

  defp market_view_path("map"), do: ~p"/control/market?view=map"
  defp market_view_path(_tiles), do: ~p"/control/market"

  defp map_region_name(galaxy, region_id) do
    case Enum.find(galaxy.nodes, &(&1.id == region_id)) do
      %{name: name} -> name
      nil -> Integer.to_string(region_id)
    end
  end

  # Anillo de la región: páginas mientras descarga; si no, tiempo hasta `Expires`.
  defp map_fraction(%{status: :fetching} = status, _now), do: pages_fraction(status)
  defp map_fraction(status, now), do: expires_fraction(status, now)

  defp region_title(node, status, label, heat) do
    poller =
      if status,
        do: "#{label} · #{Format.compact(status.orders)} #{gettext("órdenes")}",
        else: label

    [node.name, poller, heat_text(heat)] |> Enum.reject(&is_nil/1) |> Enum.join(" · ")
  end

  defp heat_text(nil), do: nil
  defp heat_text(%{kills: 0}), do: nil

  defp heat_text(%{alerts: 0, kills: kills}),
    do: ngettext("%{count} kill", "%{count} kills", kills)

  defp heat_text(%{alerts: alerts, kills: kills}) do
    ngettext("%{count} sistema en alerta", "%{count} sistemas en alerta", alerts) <>
      ", " <> ngettext("%{count} kill", "%{count} kills", kills)
  end

  attr :map, :map, required: true, doc: "`Eth.Sde.region_map/1`"
  attr :heat, :map, required: true, doc: "calor del radar por sistema"
  attr :layer, :atom, required: true

  # Sistemas de una región: color de seguridad, stargates internos y kills del radar.
  defp region_systems_map(assigns) do
    assigns =
      assign(assigns,
        points: Map.new(assigns.map.nodes, &{&1.id, &1}),
        radar?: assigns.layer in [:radar, :both],
        all_names?: length(assigns.map.nodes) <= 40
      )

    ~H"""
    <svg
      id="region-systems-map"
      viewBox={"0 0 #{@map.width} #{@map.height}"}
      class="h-auto w-full"
      role="img"
      aria-label={gettext("Sistemas de la región")}
    >
      <g aria-hidden="true" class="text-base-content/20">
        <line
          :for={{a, b} <- @map.links}
          x1={@points[a].x}
          y1={@points[a].y}
          x2={@points[b].x}
          y2={@points[b].y}
          stroke="currentColor"
          stroke-width="1"
          vector-effect="non-scaling-stroke"
        />
      </g>
      <g :for={n <- @map.nodes} id={"map-system-#{n.id}"}>
        <title>{system_title(n, @heat[n.id])}</title>
        <circle
          :if={@radar? && GalaxyMap.halo_radius(@heat[n.id], 5)}
          cx={n.x}
          cy={n.y}
          r={GalaxyMap.halo_radius(@heat[n.id], 5)}
          class={["fill-error", @heat[n.id].alerts > 0 && "eth-pulse-bar"]}
          fill-opacity={if(@heat[n.id].alerts > 0, do: "0.35", else: "0.15")}
        />
        <circle cx={n.x} cy={n.y} r="5" style={"fill: #{Sde.security_color(n.security)}"} />
        <text
          :if={@all_names? or (@radar? and @heat[n.id] != nil)}
          x={n.x}
          y={n.y - 9}
          text-anchor="middle"
          class={[
            "font-mono text-[11px]",
            if(@radar? and @heat[n.id] != nil, do: "fill-error", else: "fill-base-content/70")
          ]}
        >
          {n.name}
        </text>
      </g>
    </svg>
    """
  end

  defp system_title(node, heat) do
    sec = :erlang.float_to_binary(Sde.security_display(node.security), decimals: 1)
    [node.name, sec, heat_text(heat)] |> Enum.reject(&is_nil/1) |> Enum.join(" · ")
  end

  ## Sesiones de personajes (RF-8.6)

  defp session_resources, do: [:online, :location, :ship, :wallet, :skills, :standings, :assets]

  defp resource_label(:online), do: gettext("En línea")
  defp resource_label(:location), do: gettext("Ubicación")
  defp resource_label(:ship), do: gettext("Nave")
  defp resource_label(:wallet), do: gettext("Billetera")
  defp resource_label(:skills), do: gettext("Habilidades")
  defp resource_label(:standings), do: gettext("Standings")
  defp resource_label(:assets), do: gettext("Módulos montados")

  defp session_label(:ok), do: gettext("token vigente")
  defp session_label(:relogin), do: gettext("re-login requerido")
  defp session_label(:token_error), do: gettext("error de token")
  defp session_label(_status), do: gettext("conectando")

  defp session_kind(:ok), do: :improved
  defp session_kind(:relogin), do: :risk
  defp session_kind(:token_error), do: :scam
  defp session_kind(_status), do: :expired

  defp mode_label(:active), do: gettext("polling activo (UI abierta)")
  defp mode_label(:idle), do: gettext("en línea, sin UI")
  defp mode_label(:offline), do: gettext("offline, polling reducido")
  defp mode_label(_mode), do: ""
end
