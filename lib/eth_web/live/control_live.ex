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
    - **Mercado:** mapa de regiones por nivel con su detalle y acciones (RF-8.2, RF-8.3).
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
  alias Eth.{Clock, Engine, Events, Market, Sde, Threat}
  alias Eth.Esi.{Budget, ServerStatus}
  alias EthWeb.Format

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
         |> assign(:selected, selected_region(params, socket.assigns.selected))}

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
    {:noreply, assign(socket, :selected, selected)}
  end

  def handle_event("close_detail", _params, socket),
    do: {:noreply, assign(socket, :selected, nil)}

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
    regions =
      for status <- Map.values(assigns.regions),
          {key, label, _color} = display(status, assigns.now),
          key in [:backoff, :excluded, :stale, :degraded] do
        {:region, "#{status.name}: #{label}", ~p"/control/market?region=#{status.region_id}"}
      end

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

  # Anillo interior: páginas del ciclo en curso (o completo si está en reposo).
  defp pages_fraction(%{progress: {done, total}}) when is_integer(total) and total > 0,
    do: done / total

  defp pages_fraction(%{pages: pages}) when is_integer(pages) and pages > 0, do: 1.0
  defp pages_fraction(_status), do: 0.0

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
    assign(socket,
      feed: Threat.feed_status(),
      baseline: Threat.baseline_meta(),
      hot: Enum.take(Threat.hot_systems(), @radar_hot)
    )
  end

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
      next_downtime: ServerStatus.next_downtime(now)
    )
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
