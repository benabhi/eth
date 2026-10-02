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
      y acciones (RF-8.2, RF-8.3). El mapa (`?view=map`) es un lienzo con zoom y arrastre
      que ubica cada región según el SDE con el estado de su poller, el calor del radar, las
      oportunidades del motor y los pilotos; un clic entra a los sistemas de la región. Barra
      de capas, filtros y búsqueda, e inspector con la ficha de cada sistema.
    - **Radar:** feed, sistemas calientes y últimas kills relevantes (RF-8.5).
    - **Personajes:** sesiones y tokens, con un anillo por recurso (RF-8.6).
    - **Registros:** eventos del sistema filtrables (RF-8.7).
    - **ESI:** presupuestos por grupo y error limit (RF-8.8).

  Se actualiza por PubSub; un tick por segundo refresca las cuentas regresivas.

  Implementa: RF-1.12, RF-3.8, RF-8.1, RF-8.2, RF-8.3, RF-8.5, RF-8.6, RF-8.7, RF-8.8,
  RF-8.9, RF-8.10, RF-11.2.
  """
  use EthWeb, :live_view

  import EthWeb.TradingComponents, only: [row_detail: 1, detail_col: 1, filter_field: 1]

  alias Eth.Characters.Sessions
  alias Eth.{Clock, Engine, Events, Market, Metrics, Routing, Sde, Threat, Tracking}
  alias Eth.Sde.Galaxy
  alias Eth.Esi.{Budget, ServerStatus}
  alias EthWeb.{Format, GalaxyMap}

  @event_limit 60
  @radar_hot 15
  @radar_kills 40
  @tiers [hub: "N1 · Hubs", active: "N2 · Activas", rest: "N3 · Resto"]
  @tab_keys ~w(overview market radar characters logs esi)

  # Capas del mapa: se encienden y apagan por separado.
  @map_layers ~w(pollers radar opps pilots routes stations borders)a
  # Segundos en que un anillo destella después de un snapshot con datos nuevos.
  @ping_seconds 4

  # Por defecto solo los pollers; Rutas se enciende sola con una ruta del tablón o un viaje.
  @map_layers_default [:pollers]
  @map_options %{
    "filter" => {:map_filter, ~w(all problems heat opps)a},
    "labels" => {:map_labels, ~w(auto all)a},
    "color" => {:map_color, ~w(security heat)a}
  }

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Eth.PubSub, Market.status_topic())
      Phoenix.PubSub.subscribe(Eth.PubSub, Events.topic())
      Phoenix.PubSub.subscribe(Eth.PubSub, ServerStatus.topic())
      Phoenix.PubSub.subscribe(Eth.PubSub, Sde.topic())
      Phoenix.PubSub.subscribe(Eth.PubSub, Threat.kills_topic())
      Phoenix.PubSub.subscribe(Eth.PubSub, Engine.topic())
      # Viajes de los personajes con sesión: aparecen en el mapa al iniciarse (RF-8.2).
      for s <- Sessions.list(), do: Phoenix.PubSub.subscribe(Eth.PubSub, Tracking.topic(s.id))
      schedule_tick()
    end

    socket =
      socket
      |> assign(:page_title, gettext("Centro de control"))
      |> assign(:regions, Map.new(Market.region_statuses(), &{&1.region_id, &1}))
      |> assign(:selected, nil)
      |> assign(:region_map, nil)
      |> assign(:market_view, "tiles")
      |> assign(:map_layers, @map_layers_default)
      |> assign(map_filter: :all, map_labels: :auto, map_color: :security, map_system: nil)
      |> assign(:map_find, to_form(%{"q" => ""}, as: :find))
      |> assign(:opps, %{regions: %{}, systems: %{}})
      |> assign(url_route: nil, runs: [], trips: [], trips_shown: false)
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
         |> assign_selected(selected_region(params, socket.assigns.selected))
         |> assign_url_route(url_route(params))
         |> refresh_opps()
         |> refresh_runs()}

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

  # Un viaje empezó, avanzó o terminó: el mapa lo muestra o lo quita.
  def handle_info({:run, _run, _extra}, socket), do: {:noreply, refresh_runs(socket)}

  # Nueva evaluación del motor: las oportunidades del mapa (solo con el mapa a la vista).
  def handle_info({:opportunities_updated, _meta}, socket),
    do: {:noreply, refresh_opps(socket)}

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
     socket
     |> assign(:sessions, Sessions.list())
     |> refresh_health()
     |> refresh_radar()
     |> refresh_trips()}
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

  ## Mapa (RF-8.2)

  # Clic en una región del universo (o en una salida): se entra a sus sistemas.
  def handle_event("map_enter", %{"id" => id}, socket),
    do: {:noreply, assign_selected(socket, String.to_integer(id))}

  def handle_event("map_back", _params, socket), do: {:noreply, assign_selected(socket, nil)}

  # Clic en un sistema: su ficha en el inspector; desde una lista, además se centra.
  def handle_event("map_system", %{"id" => id} = params, socket) do
    system_id = String.to_integer(id)
    socket = assign(socket, :map_system, system_id)
    {:noreply, if(params["focus"], do: focus_system(socket, system_id), else: socket)}
  end

  def handle_event("map_system_close", _params, socket),
    do: {:noreply, assign(socket, :map_system, nil)}

  # Un piloto en el inspector: se entra a su región y se centra su sistema.
  def handle_event("map_pilot", %{"id" => id}, socket),
    do: {:noreply, go_to_system(socket, String.to_integer(id))}

  # Capas: cada una se enciende y apaga por separado.
  def handle_event("map_layer", %{"layer" => layer}, socket) do
    case Enum.find(@map_layers, &(Atom.to_string(&1) == layer)) do
      nil ->
        {:noreply, socket}

      layer ->
        layers = socket.assigns.map_layers

        layers = if layer in layers, do: List.delete(layers, layer), else: [layer | layers]

        {:noreply, assign(socket, :map_layers, layers)}
    end
  end

  # Filtro del universo, nombres y color de los sistemas. El valor va en `choice`: LiveView
  # pisa `value` con el del propio botón (vacío).
  def handle_event("map_option", %{"option" => option, "choice" => value}, socket) do
    with {key, values} <- Map.get(@map_options, option),
         value when value != nil <- Enum.find(values, &(Atom.to_string(&1) == value)) do
      {:noreply, assign(socket, key, value)}
    else
      _ -> {:noreply, socket}
    end
  end

  # Buscar: un sistema de la región a la vista, una región o cualquier sistema por nombre.
  def handle_event("map_find", %{"find" => %{"q" => query}}, socket) do
    case String.trim(query) != "" && find_target(socket.assigns, query) do
      false ->
        {:noreply, socket}

      {:system, system_id} ->
        {:noreply, socket |> go_to_system(system_id) |> clear_find()}

      {:region, region_id} ->
        {:noreply, socket |> assign_selected(region_id) |> clear_find()}

      nil ->
        {:noreply,
         socket
         |> assign(:map_find, to_form(%{"q" => query}, as: :find))
         |> put_flash(:error, gettext("No encontré «%{query}» en el mapa", query: query))}
    end
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
      system_heat: Map.new(hot, &{&1.system_id, GalaxyMap.system_heat(&1)}),
      hot_index: Map.new(hot, &{&1.system_id, &1})
    )
  end

  defp system_region(system_id) do
    case Sde.system(system_id) do
      %{region_id: region_id} -> region_id
      nil -> nil
    end
  end

  # Región elegida (detalle y, en el mapa, sus sistemas). Al cambiar de región se olvida
  # el sistema elegido.
  defp assign_selected(socket, nil),
    do: assign(socket, selected: nil, region_map: nil, map_system: nil)

  defp assign_selected(socket, region_id) do
    map_system = if socket.assigns.selected == region_id, do: socket.assigns.map_system

    assign(socket,
      selected: region_id,
      region_map: Sde.region_map(region_id),
      map_system: map_system
    )
  end

  # Oportunidades por región y sistema para el mapa: solo con el mapa a la vista, porque
  # recorre la evaluación completa del motor.
  defp refresh_opps(%{assigns: %{tab: "market", market_view: "map"}} = socket),
    do: assign(socket, :opps, GalaxyMap.opportunity_stats(Engine.all()))

  defp refresh_opps(socket), do: socket

  # Ruta abierta desde el tablón: `?route=<sistemas>&stop=<sistema de compra>`.
  defp url_route(%{"route" => route} = params) do
    case GalaxyMap.parse_route(route) do
      [_, _ | _] = path ->
        stop = route_stop(params["stop"], path)
        %{id: "route", kind: :route, label: gettext("Ruta del tablón"), path: path, stop: stop}

      _ ->
        nil
    end
  end

  defp url_route(_params), do: nil

  # Llegar con una ruta (desde la ficha del tablón) enciende la capa Rutas.
  defp assign_url_route(socket, nil), do: assign(socket, :url_route, nil)

  defp assign_url_route(socket, route) do
    socket |> assign(:url_route, route) |> enable_layer(:routes)
  end

  defp enable_layer(socket, layer) do
    if layer in socket.assigns.map_layers,
      do: socket,
      else: update(socket, :map_layers, &[layer | &1])
  end

  # Sistema de compra de la ruta: solo si es uno de sus sistemas.
  defp route_stop(text, path) do
    case Integer.parse(text || "") do
      {id, ""} -> if(id in path, do: id)
      _ -> nil
    end
  end

  # Viajes activos de los personajes con sesión (RF-7.1), solo con el mapa a la vista: la
  # lista sale de la base al abrir el mapa y con cada aviso del viaje; el camino, del tick.
  defp refresh_runs(%{assigns: %{tab: "market", market_view: "map"}} = socket) do
    runs = for s <- socket.assigns.sessions, run = Tracking.active(s.id), do: {s.name, run}

    # El primer viaje que aparece enciende la capa Rutas (después la maneja el piloto).
    socket =
      if runs != [] and not socket.assigns.trips_shown,
        do: socket |> enable_layer(:routes) |> assign(:trips_shown, true),
        else: socket

    socket |> assign(:runs, runs) |> refresh_trips()
  end

  defp refresh_runs(socket), do: assign(socket, runs: [], trips: [])

  # Camino que falta de cada viaje desde donde está el piloto: se mueve con él.
  defp refresh_trips(%{assigns: %{runs: [_ | _] = runs}} = socket) do
    trips =
      for {name, run} <- runs, path = Tracking.remaining_path(run), path != [] do
        to_origin? = run.status in ["planned", "to_origin"]

        %{
          id: "trip-#{run.id}",
          kind: :trip,
          label: gettext("Viaje de %{name}", name: name || "?"),
          detail: "#{run.plan["type_name"]} · #{Tracking.status_label(run.status)}",
          path: path,
          stop: if(to_origin?, do: run.plan["origin_system_id"])
        }
      end

    assign(socket, :trips, trips)
  end

  defp refresh_trips(socket), do: socket

  # Entra a la región del sistema, lo elige y lo centra en el lienzo.
  defp go_to_system(socket, system_id) do
    case system_region(system_id) do
      nil ->
        socket

      region_id ->
        socket
        |> assign_selected(region_id)
        |> assign(:map_system, system_id)
        |> focus_system(system_id)
    end
  end

  defp focus_system(%{assigns: %{region_map: %{nodes: nodes}}} = socket, system_id) do
    case Enum.find(nodes, &(&1.id == system_id)) do
      nil -> socket
      node -> push_event(socket, "map:focus", %{map: "map-canvas", x: node.x, y: node.y})
    end
  end

  defp focus_system(socket, _system_id), do: socket

  defp find_target(assigns, query) do
    region_nodes = if assigns.region_map, do: assigns.region_map.nodes, else: []
    galaxy_nodes = if assigns.galaxy, do: assigns.galaxy.nodes, else: []

    cond do
      node = GalaxyMap.find(region_nodes, query) -> {:system, node.id}
      node = GalaxyMap.find(galaxy_nodes, query) -> {:region, node.id}
      found = Sde.system_by_name(String.trim(query)) -> {:system, elem(found, 0)}
      true -> nil
    end
  end

  defp clear_find(socket), do: assign(socket, :map_find, to_form(%{"q" => ""}, as: :find))

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
  attr :map_link, :boolean, default: false, doc: "enlace para ver la región en el mapa"

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
        <.link
          :if={@map_link}
          id="region-detail-map"
          patch={~p"/control/market?#{[view: "map", region: r.region_id]}"}
          class="btn btn-ghost btn-sm border-base-300"
        >
          <.icon name="hero-map" class="size-4" /> {gettext("Ver en el mapa")}
        </.link>
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

  # Botones de capa de cada nivel: {capa, etiqueta, ícono}.
  defp map_layer_buttons(false) do
    [
      {:pollers, gettext("Pollers"), "hero-signal"},
      {:radar, gettext("Radar"), "hero-fire"},
      {:opps, gettext("Oportunidades"), "hero-banknotes"},
      {:pilots, gettext("Pilotos"), "hero-user"},
      {:routes, gettext("Rutas"), "hero-map-pin"}
    ]
  end

  defp map_layer_buttons(true) do
    [
      {:radar, gettext("Radar"), "hero-fire"},
      {:opps, gettext("Oportunidades"), "hero-banknotes"},
      {:pilots, gettext("Pilotos"), "hero-user"},
      {:routes, gettext("Rutas"), "hero-map-pin"},
      {:stations, gettext("Estaciones"), "hero-building-office-2"},
      {:borders, gettext("Salidas"), "hero-arrows-right-left"}
    ]
  end

  attr :option, :string, required: true
  attr :label, :string, required: true
  attr :value, :atom, required: true
  attr :choices, :list, required: true

  # Opción del mapa con valores excluyentes (filtro, nombres, color).
  defp map_choice(assigns) do
    ~H"""
    <div class="flex items-center gap-1.5">
      <span class="font-display text-[10px] tracking-[0.14em] uppercase eth-faint">{@label}</span>
      <div class="join" role="group" aria-label={@label}>
        <button
          :for={{value, text} <- @choices}
          id={"map-#{@option}-#{value}"}
          type="button"
          phx-click="map_option"
          phx-value-option={@option}
          phx-value-choice={value}
          aria-pressed={to_string(@value == value)}
          class={[
            "btn join-item btn-xs",
            if(@value == value, do: "btn-primary", else: "btn-ghost border-base-300")
          ]}
        >
          {text}
        </button>
      </div>
    </div>
    """
  end

  attr :in_region, :boolean, required: true

  # Leyenda del nivel a la vista: el color nunca va solo (RNF-5.2). Compacta, para el
  # panel plegable del lienzo.
  defp map_legend(assigns) do
    ~H"""
    <ul
      id="map-legend"
      class="grid gap-x-4 gap-y-1 text-[10.5px] leading-tight eth-muted sm:grid-cols-2"
    >
      <%= if @in_region do %>
        <li class="flex items-center gap-1.5 sm:col-span-2">
          <span class="eth-faint">{gettext("Seguridad")}</span>
          <span :for={sec <- [1.0, 0.5, 0.1, -0.5]} class="flex items-center gap-0.5 font-mono">
            <span
              class="inline-block size-1.5 rounded-full"
              style={"background: #{Sde.security_color(sec)}"}
            >
            </span>
            {security_text(sec)}
          </span>
        </li>
        <li class="flex items-center gap-1.5">
          <span class="inline-block size-2 border border-base-content/45"></span>
          {gettext("estaciones NPC")}
        </li>
        <li class="flex items-center gap-1.5">
          <span class="text-info">▸</span> {gettext("salida a otra región")}
        </li>
      <% else %>
        <li class="flex flex-wrap items-center gap-x-2 gap-y-1 sm:col-span-2">
          <span class="eth-faint">{gettext("Poller")}</span>
          <span
            :for={
              {class, label} <- [
                {"bg-success", gettext("fresco")},
                {"bg-info", gettext("descargando")},
                {"bg-warning", gettext("degradado")},
                {"bg-error", gettext("error")},
                {"bg-base-content/30", gettext("sin poller")}
              ]
            }
            class="flex items-center gap-1"
          >
            <span class={["inline-block size-1.5 rounded-full", class]}></span>
            {label}
          </span>
        </li>
      <% end %>
      <li class="flex items-center gap-1.5">
        <span class="inline-block size-2 rounded-full bg-error/30"></span>
        {gettext("halo: calor del radar")}
      </li>
      <li class="flex items-center gap-1.5">
        <span class="border border-success px-0.5 font-mono text-[8px] leading-none text-success">
          12
        </span>
        {gettext("oportunidades que compran ahí")}
      </li>
      <li class="flex items-center gap-1.5">
        <span class="text-[9px] text-accent">▼</span> {gettext("piloto")}
      </li>
      <li class="flex items-center gap-1.5">
        <span class="inline-block h-0.5 w-3 bg-primary"></span> {gettext("ruta del tablón")}
      </li>
      <li class="flex items-center gap-1.5 sm:col-span-2">
        <span class="inline-block h-0.5 w-3 bg-accent"></span>
        {gettext("viaje activo (anillo: compra · doble: venta)")}
      </li>
      <li :if={@in_region} class="flex items-center gap-1.5 sm:col-span-2">
        <span class="text-primary">⇢</span>
        {gettext("la ruta entra desde otra región o sigue hacia otra")}
      </li>
    </ul>
    """
  end

  attr :id, :string, required: true
  attr :key, :string, required: true, doc: "nivel dibujado: al cambiar, la vista vuelve a 100 %"
  slot :inner_block, required: true
  slot :legend, doc: "leyenda plegable en la esquina inferior izquierda"

  # Lienzo del mapa (hook .MapCanvas): zoom con la rueda, los botones o el teclado,
  # arrastre para desplazarse, doble clic para acercarse, pantalla completa y tooltip.
  defp map_canvas(assigns) do
    ~H"""
    <div
      id={@id}
      phx-hook=".MapCanvas"
      data-key={@key}
      class="eth-map relative overflow-hidden"
    >
      {render_slot(@inner_block)}
      <details
        :if={@legend != []}
        id={"#{@id}-legend"}
        phx-mounted={JS.ignore_attributes(["open"])}
        class="eth-map-legend absolute bottom-2 left-2 z-10 max-w-[calc(100%-3.5rem)] border border-base-300 bg-base-100/90 shadow-sm backdrop-blur-sm"
      >
        <summary class="flex items-center gap-1.5 px-2 py-1 font-display text-[10px] tracking-[0.14em] uppercase eth-muted transition-colors hover:text-primary">
          <.icon name="hero-information-circle" class="size-3.5" /> {gettext("Leyenda")}
        </summary>
        <div class="max-h-48 overflow-y-auto border-t border-base-300 px-2.5 py-2">
          {render_slot(@legend)}
        </div>
      </details>
      <div
        id={"#{@id}-tip"}
        data-map-tip
        phx-update="ignore"
        phx-mounted={JS.ignore_attributes(["class", "style"])}
        class="eth-map-tip pointer-events-none absolute left-0 top-0 z-10 hidden"
      >
      </div>
      <div
        class="absolute right-2 bottom-2 z-10 flex flex-col items-stretch border border-base-300 bg-base-100/90 shadow-sm"
        role="toolbar"
        aria-label={gettext("Zoom del mapa")}
      >
        <button
          :for={
            {action, icon, label} <- [
              {"in", "hero-plus", gettext("Acercar (+)")},
              {"out", "hero-minus", gettext("Alejar (−)")},
              {"fit", "hero-arrows-pointing-in", gettext("Ver todo (0)")},
              {"full", "hero-arrows-pointing-out", gettext("Pantalla completa (F)")}
            ]
          }
          type="button"
          id={"#{@id}-#{action}"}
          data-map-action={action}
          title={label}
          aria-label={label}
          class="flex size-8 items-center justify-center border-b border-base-300 transition-colors hover:bg-base-200 hover:text-primary"
        >
          <.icon name={icon} class="size-4" />
        </button>
        <span
          id={"#{@id}-zoom"}
          data-map-zoom
          phx-update="ignore"
          class="py-1 text-center font-mono text-[10px] tabular-nums eth-faint"
        >
          100 %
        </span>
      </div>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".MapCanvas">
      export default {
        mounted() {
          this.svg = this.el.querySelector("svg[data-map-svg]")
          this.tip = this.el.querySelector("[data-map-tip]")
          this.zoomLabel = this.el.querySelector("[data-map-zoom]")
          const vb = this.svg.viewBox.baseVal
          this.base = {x: vb.x, y: vb.y, w: vb.width, h: vb.height}
          this.view = {...this.base}
          this.key = this.el.dataset.key
          this.apply()

          // Alejarse del todo deja la rueda a la página: el mapa no atrapa el scroll.
          this.onWheel = (e) => {
            if (!e.target.closest("svg")) return
            if (e.deltaY > 0 && this.view.w >= this.base.w) return
            e.preventDefault()
            this.zoomAt(this.point(e), e.deltaY < 0 ? 1 / 1.25 : 1.25)
          }
          this.onDown = (e) => {
            if (e.button !== 0 || e.pointerType === "touch" || !e.target.closest("svg")) return
            this.drag = {x: e.clientX, y: e.clientY, view: {...this.view}, moved: false, id: e.pointerId}
          }
          this.onMove = (e) => {
            if (!this.drag) return this.showTip(e)
            const dx = e.clientX - this.drag.x
            const dy = e.clientY - this.drag.y
            if (!this.drag.moved) {
              if (Math.abs(dx) + Math.abs(dy) < 4) return
              this.drag.moved = true
              this.el.setPointerCapture(this.drag.id)
              this.svg.classList.add("cursor-grabbing")
              this.hideTip()
            }
            const s = this.unitsPerPixel()
            const start = this.drag.view
            this.view = this.clamp({...start, x: start.x - dx * s, y: start.y - dy * s})
            this.apply()
          }
          this.onUp = () => {
            if (!this.drag) return
            this.suppressClick = this.drag.moved
            this.svg.classList.remove("cursor-grabbing")
            if (this.el.hasPointerCapture(this.drag.id)) this.el.releasePointerCapture(this.drag.id)
            this.drag = null
          }
          // Un arrastre no es un clic: no elige la región que quedó bajo el puntero.
          this.onClick = (e) => {
            if (!this.suppressClick) return
            this.suppressClick = false
            e.stopPropagation()
            e.preventDefault()
          }
          this.onDblClick = (e) => {
            if (!e.target.closest("svg") || e.target.closest("[data-tip]")) return
            e.preventDefault()
            this.zoomAt(this.point(e), 1 / 1.8)
          }
          this.onLeave = () => this.hideTip()
          this.onAction = (e) => {
            const button = e.target.closest("[data-map-action]")
            if (!button || !this.el.contains(button)) return
            this.act(button.dataset.mapAction)
          }
          this.onKey = (e) => {
            if (e.target.closest("input, select, textarea")) return
            const action = {"+": "in", "=": "in", "-": "out", "0": "fit", "f": "full"}[e.key]
            if (!action) return
            e.preventDefault()
            this.act(action)
          }

          this.resize = new ResizeObserver(() => this.grid())
          this.resize.observe(this.el)
          // Escucha el contenedor: al entrar o salir de una región el svg cambia y todo sigue.
          this.el.addEventListener("wheel", this.onWheel, {passive: false})
          this.el.addEventListener("pointerdown", this.onDown)
          this.el.addEventListener("pointermove", this.onMove)
          this.el.addEventListener("pointerup", this.onUp)
          this.el.addEventListener("pointercancel", this.onUp)
          this.el.addEventListener("pointerleave", this.onLeave)
          this.el.addEventListener("click", this.onClick, true)
          this.el.addEventListener("dblclick", this.onDblClick)
          this.el.addEventListener("click", this.onAction)
          this.el.addEventListener("keydown", this.onKey)

          // Buscar: el servidor pide centrar un punto (región o sistema encontrado).
          this.handleEvent("map:focus", ({map, x, y}) => {
            if (map !== this.el.id) return
            const w = Math.min(this.view.w, this.base.w / 3)
            const h = (w * this.base.h) / this.base.w
            this.view = this.clamp({x: x - w / 2, y: y - h / 2, w, h})
            this.apply()
          })
        },
        destroyed() {
          this.resize.disconnect()
        },
        // Universo o región: con otro nivel (otro svg) se vuelve a la vista completa.
        updated() {
          this.svg = this.el.querySelector("svg[data-map-svg]")
          this.tip = this.el.querySelector("[data-map-tip]")
          this.zoomLabel = this.el.querySelector("[data-map-zoom]")
          if (this.el.dataset.key !== this.key) {
            this.key = this.el.dataset.key
            this.view = {...this.base}
          }
          this.apply()
        },
        act(action) {
          const center = {x: this.view.x + this.view.w / 2, y: this.view.y + this.view.h / 2}
          if (action === "in") this.zoomAt(center, 1 / 1.5)
          if (action === "out") this.zoomAt(center, 1.5)
          if (action === "fit") {
            this.view = {...this.base}
            this.apply()
          }
          // Pantalla completa del visor entero (barra, lienzo e inspector), no solo del svg.
          if (action === "full") {
            const frame = this.el.closest("[data-map-frame]") || this.el
            if (document.fullscreenElement) document.exitFullscreen()
            else if (frame.requestFullscreen) frame.requestFullscreen()
          }
        },
        point(e) {
          const pt = this.svg.createSVGPoint()
          pt.x = e.clientX
          pt.y = e.clientY
          return pt.matrixTransform(this.svg.getScreenCTM().inverse())
        },
        unitsPerPixel() {
          const ctm = this.svg.getScreenCTM()
          return ctm && ctm.a ? 1 / ctm.a : 1
        },
        // Zoom manteniendo fijo el punto `p` (bajo el puntero): de 1× a 12×.
        zoomAt(p, factor) {
          const w = Math.min(Math.max(this.view.w * factor, this.base.w / 12), this.base.w)
          const ratio = w / this.view.w
          const h = this.view.h * ratio
          const x = p.x - (p.x - this.view.x) * ratio
          const y = p.y - (p.y - this.view.y) * ratio
          this.view = this.clamp({x, y, w, h})
          this.apply()
        },
        // El centro de la vista nunca sale del lienzo: el dibujo no se pierde de vista.
        clamp(v) {
          const b = this.base
          const cx = Math.min(Math.max(v.x + v.w / 2, b.x), b.x + b.w)
          const cy = Math.min(Math.max(v.y + v.h / 2, b.y), b.y + b.h)
          return {x: cx - v.w / 2, y: cy - v.h / 2, w: v.w, h: v.h}
        },
        // Las marcas y los nombres conservan su tamaño en pantalla (--glyph): al acercarse se
        // separan en lugar de crecer, y con zoom cercano aparecen los nombres secundarios.
        apply() {
          const v = this.view
          const k = this.base.w / v.w
          this.svg.setAttribute("viewBox", `${v.x} ${v.y} ${v.w} ${v.h}`)
          this.svg.style.setProperty("--glyph", (1 / k).toFixed(4))
          this.svg.dataset.zoomed = k >= 1.8 ? "near" : "far"
          if (this.zoomLabel) this.zoomLabel.textContent = `${Math.round(k * 100)} %`
          this.grid()
        },
        // Grilla de fondo apenas visible que acompaña el zoom y el arrastre (da profundidad
        // sin competir con el dibujo): el paso se mantiene entre 24 y 48 px en pantalla.
        // Con la matriz de pantalla: vale también en pantalla completa, donde el dibujo queda
        // centrado con márgenes (preserveAspectRatio).
        grid() {
          const ctm = this.svg.getScreenCTM()
          if (!ctm || !ctm.a) return
          const box = this.svg.getBoundingClientRect()
          let step = 50 * ctm.a
          while (step > 48) step /= 2
          while (step < 24) step *= 2
          const mod = (n) => ((n % step) + step) % step
          this.svg.style.setProperty("--grid-step", `${step.toFixed(2)}px`)
          this.svg.style.setProperty("--grid-x", `${mod(ctm.e - box.left).toFixed(2)}px`)
          this.svg.style.setProperty("--grid-y", `${mod(ctm.f - box.top).toFixed(2)}px`)
        },
        // Tooltip: título y filas "etiqueta⇥valor" (solo texto: nada de HTML del servidor).
        renderTip(target) {
          if (this.tipTarget === target && this.tipText === target.dataset.tip) return
          this.tipTarget = target
          this.tipText = target.dataset.tip
          const [title, ...lines] = this.tipText.split("\n")
          const head = document.createElement("div")
          head.className = "eth-map-tip-title"
          head.textContent = title
          const rows = document.createElement("dl")
          rows.className = "eth-map-tip-rows"
          for (const line of lines) {
            const [label, value] = line.split("\t")
            const dt = document.createElement("dt")
            const dd = document.createElement("dd")
            dt.textContent = label
            dd.textContent = value || ""
            rows.append(dt, dd)
          }
          this.tip.replaceChildren(head, rows)
          this.tip.style.borderLeftColor = target.dataset.tipColor || ""
        },
        showTip(e) {
          const target = e.target.closest("[data-tip]")
          if (!target || !this.tip) return this.hideTip()
          this.renderTip(target)
          this.tip.classList.remove("hidden")
          const box = this.el.getBoundingClientRect()
          let left = e.clientX - box.left + 14
          let top = e.clientY - box.top + 14
          if (left + this.tip.offsetWidth > box.width - 4) left -= this.tip.offsetWidth + 28
          if (top + this.tip.offsetHeight > box.height - 4) top -= this.tip.offsetHeight + 28
          this.tip.style.left = `${Math.max(left, 4)}px`
          this.tip.style.top = `${Math.max(top, 4)}px`
        },
        hideTip() {
          if (this.tip) this.tip.classList.add("hidden")
          this.tipTarget = null
        }
      }
    </script>
    """
  end

  attr :id, :string, required: true
  attr :map, :map, required: true
  attr :label, :string, required: true
  attr :rest, :global
  slot :inner_block, required: true

  # El svg del lienzo: el hook maneja viewBox, `--glyph`, `data-zoomed` y el cursor (el
  # servidor no los pisa al redibujar cada segundo).
  defp map_svg(assigns) do
    ~H"""
    <svg
      id={@id}
      data-map-svg
      viewBox={"0 0 #{@map.width} #{@map.height}"}
      phx-mounted={JS.ignore_attributes(["viewBox", "style", "class", "data-zoomed"])}
      class="block h-auto w-full cursor-grab select-none"
      role="group"
      aria-label={@label}
      {@rest}
    >
      {render_slot(@inner_block)}
    </svg>
    """
  end

  attr :points, :map, required: true
  attr :links, :list, required: true
  attr :class, :string, required: true

  defp map_links(assigns) do
    ~H"""
    <g aria-hidden="true" class={@class}>
      <line
        :for={{a, b} <- @links}
        x1={@points[a].x}
        y1={@points[a].y}
        x2={@points[b].x}
        y2={@points[b].y}
        stroke="currentColor"
        stroke-width="1"
        vector-effect="non-scaling-stroke"
      />
    </g>
    """
  end

  attr :map, :map, required: true, doc: "`Eth.Sde.galaxy/0`"
  attr :regions, :map, required: true
  attr :heat, :map, required: true
  attr :opps, :map, required: true, doc: "oportunidades por región"
  attr :pilots, :map, required: true, doc: "pilotos por región"
  attr :layers, :list, required: true
  attr :filter, :atom, required: true
  attr :labels, :atom, required: true
  attr :selected, :integer, default: nil
  attr :routes, :list, default: [], doc: "rutas a dibujar (`map_routes/3`)"
  attr :now, :any, required: true

  defp galaxy_map(assigns) do
    max_orders =
      assigns.regions |> Map.values() |> Enum.map(&(&1.orders || 0)) |> Enum.max(fn -> 1 end)

    assigns =
      assign(assigns,
        points: Map.new(assigns.map.nodes, &{&1.id, &1}),
        max_orders: max(max_orders, 1),
        routes: universe_routes(assigns.routes, Map.new(assigns.map.nodes, &{&1.id, &1}))
      )

    ~H"""
    <.map_svg id="galaxy-map" map={@map} label={gettext("Mapa de regiones")}>
      <.map_links points={@points} links={@map.links} class="text-base-content/15" />
      <.universe_route_lines routes={@routes} />
      <.map_region
        :for={n <- @map.nodes}
        node={n}
        status={@regions[n.id]}
        heat={@heat[n.id]}
        opps={@opps[n.id]}
        pilots={Map.get(@pilots, n.id, [])}
        layers={@layers}
        filter={@filter}
        labels={@labels}
        selected={@selected == n.id}
        max_orders={@max_orders}
        now={@now}
      />
      <.route_marks_layer routes={@routes} />
    </.map_svg>
    """
  end

  attr :node, :map, required: true
  attr :status, :map, default: nil, doc: "estado del poller (`nil` si la región no se sigue)"
  attr :heat, :map, default: nil
  attr :opps, :map, default: nil
  attr :pilots, :list, default: []
  attr :layers, :list, required: true
  attr :filter, :atom, required: true
  attr :labels, :atom, required: true
  attr :selected, :boolean, default: false
  attr :max_orders, :integer, required: true
  attr :now, :any, required: true

  # Una región: anillo con el estado y la cuenta regresiva de su poller, tamaño según sus
  # órdenes, halo rojo con el calor del radar, cuántas oportunidades compran ahí y una
  # marca si hay un piloto. Clic: entra a la región.
  defp map_region(assigns) do
    %{status: status, heat: heat, now: now} = assigns
    {key, label, color} = region_display(status, now)
    r = region_radius(status, assigns.max_orders)
    flags = region_flags(assigns)

    assigns =
      assigns
      |> assign(flags)
      |> assign(poller_motion(status, key, now))
      |> assign(
        r: r,
        label: label,
        color: color,
        halo: flags.radar? && GalaxyMap.halo_radius(heat, r),
        opps_count: opps_count(assigns.layers, assigns.opps),
        fraction: status && map_fraction(status, now),
        dim?: not GalaxyMap.region_matches?(assigns.filter, key, heat, assigns.opps),
        minor?: not flags.major? and assigns.labels != :all,
        tip: region_tip(assigns.node, status, label, heat, assigns.opps, assigns.pilots, now)
      )

    ~H"""
    <g
      id={"map-region-#{@node.id}"}
      transform={"translate(#{@node.x} #{@node.y})"}
      class={["cursor-pointer outline-none transition-opacity", @dim? && "opacity-20"]}
      role="button"
      tabindex="0"
      phx-click="map_enter"
      phx-keydown="map_enter"
      phx-key="Enter"
      phx-value-id={@node.id}
      aria-label={"#{@node.name}: #{@label}"}
      aria-pressed={to_string(@selected)}
      data-tip={@tip}
      data-tip-color={tone_color(@color)}
    >
      <g class="eth-map-glyph">
        <circle r={max(@r + 5, 10)} class="fill-transparent" />
        <circle
          :if={@halo}
          r={@halo}
          class={["fill-error", @alerts? && "eth-pulse-bar"]}
          fill-opacity={if(@alerts?, do: "0.3", else: "0.12")}
        />
        <%= if @pollers? do %>
          <%!-- Datos nuevos: un destello que se expande una sola vez (un elemento por generación) --%>
          <circle
            :if={@ping}
            id={"map-ping-#{@node.id}-#{@ping}"}
            r={@r}
            fill="none"
            stroke="currentColor"
            stroke-width="2"
            class={["eth-map-ping", tone_text(@color)]}
          />
          <circle
            r={@r}
            class={["fill-base-100", tone_text(@color), @alarm? && "eth-map-alarm"]}
            stroke="currentColor"
            stroke-opacity="0.3"
            stroke-width="2"
          />
          <circle
            r={@r}
            fill="none"
            stroke="currentColor"
            class={["eth-map-arc", tone_text(@color)]}
            stroke-width="2.5"
            stroke-dasharray={GalaxyMap.arc_dash(@fraction, @r)}
            transform="rotate(-90)"
          />
          <%!-- Descargando: un tramo corto que gira por fuera del anillo --%>
          <circle
            :if={@fetching?}
            r={@r + 3}
            fill="none"
            stroke="currentColor"
            stroke-width="1.5"
            stroke-linecap="round"
            stroke-dasharray={GalaxyMap.arc_dash(0.2, @r + 3)}
            class="eth-map-spin text-info"
          />
          <circle r="2.5" fill="currentColor" class={tone_text(@color)} />
        <% else %>
          <circle
            r={if(@status, do: 4, else: 3)}
            class={if(@status, do: "fill-base-content/50", else: "fill-base-content/25")}
          />
        <% end %>
        <.map_count :if={@opps_count > 0} x={@r + 2} y={-@r - 2} count={@opps_count} />
        <.map_pilot :if={@pilots?} y={-@r - 4} />
        <circle
          :if={@selected}
          r={@r + 5}
          fill="none"
          stroke="currentColor"
          class="text-primary"
          stroke-width="1.5"
        />
        <text
          y={@r + 14}
          text-anchor="middle"
          class={[
            "font-display text-[12px]",
            @minor? && "eth-map-label-minor",
            if(@selected, do: "fill-primary", else: "fill-base-content/80")
          ]}
        >
          {@node.name}
        </text>
      </g>
    </g>
    """
  end

  defp region_display(nil, _now), do: {nil, gettext("Sin poller"), "neutral"}
  defp region_display(status, now), do: display(status, now)

  defp region_radius(nil, _max_orders), do: 3.5
  defp region_radius(status, max_orders), do: GalaxyMap.node_radius(status.orders, max_orders)

  # Qué se dibuja de una región según las capas encendidas; las importantes llevan nombre
  # siempre (hubs, la elegida, con alertas o con un piloto).
  defp region_flags(%{status: status, heat: heat, layers: layers} = assigns) do
    radar? = :radar in layers
    alerts? = radar? and alerted?(heat)
    pilots? = :pilots in layers and assigns.pilots != []

    %{
      radar?: radar?,
      alerts?: alerts?,
      pilots?: pilots?,
      pollers?: status != nil and :pollers in layers,
      major?: hub?(status) or assigns.selected or alerts? or pilots?
    }
  end

  # Animaciones del anillo: descarga en curso, error o límite (parpadeo) y datos nuevos
  # (destello, solo en los segundos después de un snapshot con cambios).
  defp poller_motion(nil, _key, _now), do: %{fetching?: false, alarm?: false, ping: nil}

  defp poller_motion(status, key, now) do
    %{
      fetching?: status.status == :fetching,
      alarm?: key in [:backoff, :rate_limited],
      ping: if(fresh_snapshot?(status, now), do: status[:generation])
    }
  end

  defp fresh_snapshot?(%{history: [%{at: %DateTime{} = at} = last | _]}, now) do
    changed? = Map.get(last, :not_modified, 0) < Map.get(last, :pages, 1)
    changed? and DateTime.diff(now, at) <= @ping_seconds
  end

  defp fresh_snapshot?(_status, _now), do: false

  defp hub?(%{tier: :hub}), do: true
  defp hub?(_status), do: false

  defp alerted?(%{alerts: alerts}), do: alerts > 0
  defp alerted?(_heat), do: false

  # Oportunidades que compran en el lugar, si la capa está encendida.
  defp opps_count(layers, %{buy: buy}), do: if(:opps in layers, do: buy, else: 0)
  defp opps_count(_layers, _opps), do: 0

  attr :x, :any, required: true
  attr :y, :any, required: true
  attr :count, :integer, required: true

  # Cuántas oportunidades compran en el lugar: una píldora verde arriba a la derecha.
  defp map_count(assigns) do
    assigns = assign(assigns, :text, Format.compact(assigns.count))

    ~H"""
    <g transform={"translate(#{@x} #{@y})"} aria-hidden="true">
      <rect
        x="0"
        y="-7"
        width={6 + 6 * String.length(@text)}
        height="12"
        rx="2"
        class="fill-base-100 stroke-success"
        stroke-width="1"
      />
      <text x="3" y="2.5" class="fill-success font-mono text-[9px]">{@text}</text>
    </g>
    """
  end

  attr :y, :any, required: true

  # Marca de piloto: un triángulo que apunta al lugar.
  defp map_pilot(assigns) do
    ~H"""
    <path
      d={"M 0 #{@y} l -4.5 -7 h 9 z"}
      class="fill-accent stroke-base-100"
      stroke-width="1"
      aria-hidden="true"
    />
    """
  end

  attr :map, :map, required: true, doc: "`Eth.Sde.region_map/1`"
  attr :heat, :map, required: true, doc: "calor del radar por sistema"
  attr :opps, :map, required: true, doc: "oportunidades por sistema"
  attr :pilots, :map, required: true, doc: "pilotos por sistema"
  attr :layers, :list, required: true
  attr :labels, :atom, required: true
  attr :color, :atom, required: true
  attr :selected, :integer, default: nil
  attr :routes, :list, default: [], doc: "rutas a dibujar (`map_routes/3`)"

  # Sistemas de una región: color de seguridad (o de calor), stargates internos, kills del
  # radar, estaciones, salidas a otras regiones, oportunidades y pilotos.
  defp region_systems_map(assigns) do
    assigns =
      assign(assigns,
        points: Map.new(assigns.map.nodes, &{&1.id, &1}),
        all_names: assigns.labels == :all or length(assigns.map.nodes) <= 40
      )

    assigns =
      assign(assigns, :routes, region_routes(assigns.routes, assigns.points, assigns.map.frame))

    ~H"""
    <.map_svg id="region-systems-map" map={@map} label={gettext("Sistemas de la región")}>
      <.map_links points={@points} links={@map.links} class="text-base-content/20" />
      <.region_route_lines routes={@routes} points={@points} />
      <.map_system
        :for={n <- @map.nodes}
        node={n}
        heat={@heat[n.id]}
        opps={@opps[n.id]}
        pilots={Map.get(@pilots, n.id, [])}
        layers={@layers}
        color={@color}
        all_names={@all_names}
        selected={@selected == n.id}
      />
      <.route_marks_layer routes={@routes} />
    </.map_svg>
    """
  end

  attr :node, :map, required: true
  attr :heat, :map, default: nil
  attr :opps, :map, default: nil
  attr :pilots, :list, default: []
  attr :layers, :list, required: true
  attr :color, :atom, required: true
  attr :all_names, :boolean, required: true
  attr :selected, :boolean, default: false

  defp map_system(assigns) do
    %{node: node, layers: layers} = assigns

    assigns =
      assigns
      |> assign(system_flags(assigns))
      |> assign(
        stations?: :stations in layers and node.stations > 0,
        exits: if(:borders in layers, do: node.exits, else: []),
        opps_count: opps_count(layers, assigns.opps),
        tip: system_tip(node, assigns.heat, assigns.opps, assigns.pilots)
      )

    ~H"""
    <g
      id={"map-system-#{@node.id}"}
      transform={"translate(#{@node.x} #{@node.y})"}
      class="cursor-pointer outline-none"
      role="button"
      tabindex="0"
      phx-click="map_system"
      phx-keydown="map_system"
      phx-key="Enter"
      phx-value-id={@node.id}
      aria-label={@node.name}
      aria-pressed={to_string(@selected)}
      data-tip={@tip}
      data-tip-color={Sde.security_color(@node.security)}
    >
      <g class="eth-map-glyph">
        <circle r="10" class="fill-transparent" />
        <circle
          :if={@halo}
          r={@halo}
          class={["fill-error", @alerts? && "eth-pulse-bar"]}
          fill-opacity={if(@alerts?, do: "0.35", else: "0.15")}
        />
        <rect
          :if={@stations?}
          x="-8"
          y="-8"
          width="16"
          height="16"
          fill="none"
          class="stroke-base-content/45"
          stroke-width="1"
        />
        <circle
          :if={@color == :security}
          r="5"
          style={"fill: #{Sde.security_color(@node.security)}"}
        />
        <circle :if={@color == :heat} r="5" class={GalaxyMap.heat_class(@heat)} />
        <path
          :if={@exits != []}
          d="M 9 -3 l 4 3 l -4 3 z"
          class="fill-info"
          aria-hidden="true"
        />
        <.map_count :if={@opps_count > 0} x="7" y="-8" count={@opps_count} />
        <.map_pilot :if={@pilots?} y="-9" />
        <circle
          :if={@selected}
          r="11"
          fill="none"
          stroke="currentColor"
          class="text-primary"
          stroke-width="1.5"
        />
        <text
          y="-12"
          text-anchor="middle"
          class={[
            "font-mono text-[11px]",
            @minor? && "eth-map-label-minor",
            cond do
              @selected -> "fill-primary"
              @hot? -> "fill-error"
              true -> "fill-base-content/70"
            end
          ]}
        >
          {@node.name}
        </text>
        <text
          :if={@exits != []}
          y="19"
          text-anchor="middle"
          class="eth-map-label-minor fill-info font-display text-[9px]"
        >
          → {Enum.map_join(@exits, " · ", & &1.name)}
        </text>
      </g>
    </g>
    """
  end

  # Qué se dibuja de un sistema: halo del radar, piloto y si lleva nombre siempre.
  defp system_flags(%{heat: heat, layers: layers} = assigns) do
    hot? = :radar in layers and heat != nil
    pilots? = :pilots in layers and assigns.pilots != []

    %{
      hot?: hot?,
      pilots?: pilots?,
      halo: hot? && GalaxyMap.halo_radius(heat, 5),
      alerts?: hot? and alerted?(heat),
      minor?: not (assigns.all_names or hot? or pilots? or assigns.selected)
    }
  end

  defp market_view_path("map"), do: ~p"/control/market?view=map"
  defp market_view_path(_tiles), do: ~p"/control/market"

  defp map_region_name(galaxy, region_id) do
    case galaxy && Enum.find(galaxy.nodes, &(&1.id == region_id)) do
      %{name: name} -> name
      _ -> Integer.to_string(region_id)
    end
  end

  # Anillo de la región: páginas mientras descarga; si no, tiempo hasta `Expires`.
  defp map_fraction(%{status: :fetching} = status, _now), do: pages_fraction(status)
  defp map_fraction(status, now), do: expires_fraction(status, now)

  # Tooltip de una región o un sistema: el título y filas "etiqueta⇥valor", una por línea
  # (el hook .MapCanvas las arma como lista; sin HTML del servidor).
  defp region_tip(node, status, label, heat, opps, pilots, now) do
    poller =
      if status,
        do: [
          {gettext("Poller"), "#{label} · #{timing(status, now)}"},
          {gettext("Órdenes"), Format.compact(status.orders)}
        ],
        else: [{gettext("Poller"), label}]

    tip_text(node.name, poller ++ tip_rows(heat, opps, pilots))
  end

  defp system_tip(node, heat, opps, pilots) do
    rows =
      [
        {gettext("Seguridad"), security_text(node.security)},
        node.stations > 0 && {gettext("Estaciones"), Integer.to_string(node.stations)},
        node.exits != [] && {gettext("Salidas"), Enum.map_join(node.exits, ", ", & &1.name)}
      ]
      |> Enum.filter(& &1)

    tip_text(node.name, rows ++ tip_rows(heat, opps, pilots))
  end

  defp tip_rows(heat, opps, pilots) do
    [
      heat_text(heat) && {gettext("Radar"), heat_text(heat)},
      opps &&
        {gettext("Oportunidades"),
         gettext("%{buy} compran · %{sell} venden",
           buy: Format.integer(opps.buy),
           sell: Format.integer(opps.sell)
         )},
      opps && {gettext("Mejor"), "#{Format.compact(opps.best)} ISK"},
      pilots != [] && {gettext("Pilotos"), Enum.join(pilots, ", ")}
    ]
    |> Enum.filter(& &1)
  end

  defp tip_text(title, rows),
    do: Enum.join([title | Enum.map(rows, fn {k, v} -> "#{k}\t#{v}" end)], "\n")

  defp heat_tone(%{alerts: alerts}) when alerts > 0, do: "text-error"
  defp heat_tone(_heat), do: "text-warning"

  # Color de la franja del tooltip: el del estado del poller.
  defp tone_color("success"), do: "var(--color-success)"
  defp tone_color("info"), do: "var(--color-info)"
  defp tone_color("error"), do: "var(--color-error)"
  defp tone_color("warning"), do: "var(--color-warning)"
  defp tone_color("secondary"), do: "var(--color-secondary)"
  defp tone_color(_neutral), do: "var(--eth-faint)"

  defp security_text(sec), do: :erlang.float_to_binary(Sde.security_display(sec), decimals: 1)

  defp heat_text(nil), do: nil
  defp heat_text(%{kills: 0}), do: nil

  defp heat_text(%{alerts: 0, kills: kills}),
    do: ngettext("%{count} kill", "%{count} kills", kills)

  defp heat_text(%{alerts: alerts, kills: kills}) do
    ngettext("%{count} sistema en alerta", "%{count} sistemas en alerta", alerts) <>
      ", " <> ngettext("%{count} kill", "%{count} kills", kills)
  end

  # Pilotos por región (para el universo) a partir de los pilotos por sistema.
  defp pilots_by_region(pilots) do
    Enum.reduce(pilots, %{}, fn {system_id, names}, acc ->
      case system_region(system_id) do
        nil -> acc
        region_id -> Map.update(acc, region_id, names, &(&1 ++ names))
      end
    end)
  end

  # Las N primeras regiones por `fun` (solo las que tienen algo).
  defp top_regions(stats, fun, n) do
    stats
    |> Enum.map(fn {id, s} -> {id, fun.(s)} end)
    |> Enum.filter(fn {_id, v} -> v > 0 end)
    |> Enum.sort_by(fn {_id, v} -> -v end)
    |> Enum.take(n)
  end

  # Saltos de cada piloto a un sistema, por la ruta más corta y por la segura (RF-2.4).
  defp pilot_jumps(pilots, system_id) do
    for {from, names} <- pilots, name <- names do
      %{
        name: name,
        here?: from == system_id,
        shortest: Routing.distance(from, system_id, :shortest),
        secure: Routing.distance(from, system_id, :secure)
      }
    end
  end

  defp jumps_text(nil), do: "—"
  defp jumps_text(n), do: ngettext("%{count} salto", "%{count} saltos", n)

  ## Rutas en el mapa (RF-8.2): la del tablón y los viajes activos

  # Rutas a dibujar: la abierta desde el tablón y el camino que falta de cada viaje.
  defp map_routes(layers, url_route, trips) do
    if :routes in layers, do: Enum.reject([url_route | trips], &is_nil/1), else: []
  end

  # Universo: la ruta pasa por los mismos puntos que el mapa, de región en región (el centro
  # de cada una); las marcas van en la región de su sistema.
  defp universe_routes(routes, points) do
    for route <- routes do
      place = fn system_id -> system_region(system_id) end
      regions = GalaxyMap.route_places(route.path, place)

      route
      |> Map.put(:points, for(id <- regions, n = points[id], do: {n.x, n.y}))
      |> Map.put(:marks, route_marks(route, place, points))
    end
  end

  # Región: tramos entre sus sistemas, marcas de los que están en ella y una flecha donde
  # la ruta entra desde otra región o sigue hacia otra.
  defp region_routes(routes, points, frame) do
    for route <- routes do
      crossings =
        for {dir, inside, outside} <- GalaxyMap.route_crossings(route.path, points),
            c = crossing(dir, points[inside], Sde.system(outside), frame),
            uniq: true,
            do: c

      route
      |> Map.put(:marks, route_marks(route, & &1, points))
      |> Map.put(:crossings, crossings)
    end
  end

  # Flecha de entrada o salida: sale del sistema hacia donde queda el de la otra región.
  # Medidas en unidades de la marca (tamaño constante con el zoom).
  defp crossing(dir, node, %{region_id: region_id} = system, frame) do
    with {ox, oy} <- Galaxy.project(frame, system) do
      {dx, dy} = unit(ox - node.x, oy - node.y)
      angle = :math.atan2(dy, dx) * 180 / :math.pi()
      {tip, deg} = if dir == :out, do: {46, angle}, else: {14, angle + 180}
      name = (Sde.region(region_id) || %{name: "?"}).name

      text =
        if dir == :out,
          do: gettext("hacia %{region}", region: name),
          else: gettext("desde %{region}", region: name)

      {lx, ly} = {r1(dx * 54), r1(dy * 54)}
      width = r1(10 + 5.6 * String.length(text))

      %{
        key: "#{dir}-#{node.id}-#{region_id}",
        x: node.x,
        y: node.y,
        line: {r1(dx * 12), r1(dy * 12), r1(dx * 46), r1(dy * 46)},
        tip: {r1(dx * tip), r1(dy * tip), Float.round(deg, 1)},
        label: {label_x(lx, width, anchor(dx)), ly - 7, width},
        text: text
      }
    end
  end

  defp crossing(_dir, _node, _system, _frame), do: nil

  defp unit(x, y) do
    length = :math.sqrt(x * x + y * y)
    if length < 1.0e-6, do: {1.0, 0.0}, else: {x / length, y / length}
  end

  defp r1(value), do: Float.round(value / 1, 1)

  defp anchor(dx) when dx > 0.3, do: :start
  defp anchor(dx) when dx < -0.3, do: :end
  defp anchor(_dx), do: :middle

  # Borde izquierdo de la etiqueta según hacia dónde apunta la flecha.
  defp label_x(x, _width, :start), do: x
  defp label_x(x, width, :end), do: r1(x - width)
  defp label_x(x, width, :middle), do: r1(x - width / 2)

  # Marcas de una ruta ubicadas en el lienzo: inicio, compra y venta. Si caen en el mismo
  # lugar, las etiquetas se apilan.
  defp route_marks(route, place, points) do
    route
    |> GalaxyMap.route_stops()
    |> Enum.flat_map(fn {kind, system_id} ->
      case points[place.(system_id)] do
        nil -> []
        n -> [%{kind: kind, at: n.id, x: n.x, y: n.y}]
      end
    end)
    |> Enum.group_by(& &1.at)
    |> Enum.flat_map(fn {_at, marks} ->
      marks |> Enum.with_index() |> Enum.map(fn {m, i} -> Map.put(m, :stack, i) end)
    end)
  end

  defp route_class(:trip), do: "text-accent"
  defp route_class(_route), do: "text-primary"

  defp mark_label(:start, :trip), do: gettext("Estás acá")
  defp mark_label(:start, _route), do: gettext("Inicio")
  defp mark_label(:buy, _route), do: gettext("Compra")
  defp mark_label(:sell, _route), do: gettext("Venta")

  attr :routes, :list, required: true, doc: "rutas con `points` ya en el lienzo"

  # Rutas sobre el universo: una línea por las regiones del camino. Va debajo de las
  # regiones: no tapa sus clics.
  defp universe_route_lines(assigns) do
    ~H"""
    <g
      :for={r <- @routes}
      :if={length(r.points) > 1}
      id={"map-#{r.id}"}
      class={route_class(r.kind)}
      aria-hidden="true"
    >
      <polyline
        points={Enum.map_join(r.points, " ", fn {x, y} -> "#{x},#{y}" end)}
        fill="none"
        stroke="currentColor"
        stroke-width="2.5"
        stroke-opacity="0.85"
        stroke-linejoin="round"
        stroke-linecap="round"
        vector-effect="non-scaling-stroke"
      />
    </g>
    """
  end

  attr :routes, :list, required: true
  attr :points, :map, required: true, doc: "sistemas de la región por ID"

  # Rutas dentro de una región: solo los tramos entre sistemas de la región.
  defp region_route_lines(assigns) do
    ~H"""
    <g :for={r <- @routes} id={"map-#{r.id}"} class={route_class(r.kind)} aria-hidden="true">
      <line
        :for={{a, b} <- GalaxyMap.route_links(r.path, @points)}
        x1={@points[a].x}
        y1={@points[a].y}
        x2={@points[b].x}
        y2={@points[b].y}
        stroke="currentColor"
        stroke-width="3"
        stroke-opacity="0.8"
        stroke-linecap="round"
        vector-effect="non-scaling-stroke"
      />
    </g>
    """
  end

  attr :routes, :list, required: true, doc: "rutas con `marks`"

  # Marcas de las rutas, por encima de todo y sin capturar el puntero: inicio (punto),
  # compra (anillo) y venta (anillo doble), cada una con su etiqueta.
  defp route_marks_layer(assigns) do
    ~H"""
    <g aria-hidden="true" pointer-events="none">
      <g
        :for={r <- @routes}
        id={"map-#{r.id}-marks"}
        class={route_class(r.kind)}
      >
        <g :for={c <- r[:crossings] || []} transform={"translate(#{c.x} #{c.y})"}>
          <g class="eth-map-glyph">
            <line
              x1={elem(c.line, 0)}
              y1={elem(c.line, 1)}
              x2={elem(c.line, 2)}
              y2={elem(c.line, 3)}
              stroke="currentColor"
              stroke-width="2"
              stroke-dasharray="4 3"
            />
            <path
              d="M -4 -4 L 5 0 L -4 4 z"
              fill="currentColor"
              transform={"translate(#{elem(c.tip, 0)} #{elem(c.tip, 1)}) rotate(#{elem(c.tip, 2)})"}
            />
            <%!-- Etiqueta con fondo: se lee sobre líneas y puntos sin contorno en las letras --%>
            <g transform={"translate(#{elem(c.label, 0)} #{elem(c.label, 1)})"}>
              <rect
                width={elem(c.label, 2)}
                height="14"
                rx="2"
                class="fill-base-100/90"
                stroke="currentColor"
                stroke-opacity="0.6"
                stroke-width="1"
              />
              <text
                x={elem(c.label, 2) / 2}
                y="10"
                text-anchor="middle"
                fill="currentColor"
                class="font-display text-[9px] font-semibold tracking-[0.04em]"
              >
                {c.text}
              </text>
            </g>
          </g>
        </g>
        <g
          :for={m <- r.marks}
          id={"map-#{r.id}-#{m.kind}"}
          transform={"translate(#{m.x} #{m.y})"}
        >
          <g class="eth-map-glyph">
            <%= case m.kind do %>
              <% :start -> %>
                <circle :if={m.stack == 0} r="5" fill="currentColor" class="stroke-base-100" />
              <% :buy -> %>
                <circle r="11" fill="none" stroke="currentColor" stroke-width="2.5" />
              <% :sell -> %>
                <circle r="11" fill="none" stroke="currentColor" stroke-width="2.5" />
                <circle r="15" fill="none" stroke="currentColor" stroke-width="1.5" />
            <% end %>
            <.mark_tag text={mark_label(m.kind, r.kind)} y={-22 - 15 * m.stack} />
          </g>
        </g>
      </g>
    </g>
    """
  end

  attr :text, :string, required: true
  attr :y, :integer, required: true

  # Etiqueta de una marca: una píldora del color de la ruta con el texto oscuro.
  defp mark_tag(assigns) do
    assigns = assign(assigns, :width, 10 + 6.2 * String.length(assigns.text))

    ~H"""
    <g transform={"translate(0 #{@y})"}>
      <rect x={-@width / 2} y="-7" width={@width} height="13" rx="2" fill="currentColor" />
      <text
        y="3"
        text-anchor="middle"
        class="fill-base-100 font-display text-[9px] font-semibold tracking-[0.08em] uppercase"
      >
        {@text}
      </text>
    </g>
    """
  end

  # Sistemas de la ruta por seguridad: {cantidad, etiqueta, color}, sin las vacías.
  defp band_parts(bands) do
    for {band, label, class} <- [
          {:highsec, gettext("alta"), "text-success"},
          {:lowsec, gettext("baja"), "text-warning"},
          {:nullsec, gettext("nula"), "text-error"}
        ],
        count = bands[band],
        do: {count, label, class}
  end

  attr :route, :map, required: true
  attr :hot_index, :map, required: true
  attr :galaxy, :map, required: true
  attr :remove, :string, default: nil, doc: "enlace para quitar la ruta (la del tablón)"

  # Ficha de una ruta: extremos, saltos, seguridad del camino, alertas y regiones.
  defp map_route_card(assigns) do
    path = assigns.route.path
    systems = Enum.map(path, &{&1, Sde.system(&1)})

    bands =
      systems
      |> Enum.flat_map(fn
        {_id, %{security: sec}} -> [Sde.security_band(sec)]
        _ -> []
      end)
      |> Enum.frequencies()

    assigns =
      assign(assigns,
        first: hd(path),
        last: List.last(path),
        jumps: length(path) - 1,
        band_parts: band_parts(bands),
        alerts: Enum.filter(path, &match?(%{alert: true}, assigns.hot_index[&1])),
        regions:
          systems
          |> Enum.flat_map(fn
            {_id, %{region_id: region_id}} -> [region_id]
            _ -> []
          end)
          |> Enum.dedup()
          |> Enum.uniq()
      )

    ~H"""
    <section
      id={"map-#{@route.id}-card"}
      class={[
        "eth-chamfer-sm border bg-base-200/50 p-3",
        if(@route.kind == :trip, do: "border-accent/50", else: "border-primary/40")
      ]}
    >
      <div class="flex items-start justify-between gap-2">
        <div class="min-w-0">
          <div class={["font-display text-sm", route_class(@route.kind)]}>{@route.label}</div>
          <div :if={@route[:detail]} class="truncate text-xs eth-muted">{@route.detail}</div>
        </div>
        <.link
          :if={@remove}
          id="map-route-remove"
          patch={@remove}
          aria-label={gettext("Quitar la ruta del mapa")}
          class="eth-muted transition-colors hover:text-primary"
        >
          <.icon name="hero-x-mark" class="size-4" />
        </.link>
      </div>

      <div class="mt-2 flex flex-wrap items-center gap-x-1.5 font-mono text-xs">
        <span style={sec_style(@first)}>{system_name(@first)}</span>
        <%= if @route.stop && @route.stop not in [@first, @last] do %>
          <span class="eth-faint">→</span>
          <span class="underline" style={sec_style(@route.stop)}>{system_name(@route.stop)}</span>
        <% end %>
        <span class="eth-faint">→</span>
        <span style={sec_style(@last)}>{system_name(@last)}</span>
      </div>

      <div class="mt-1 text-xs eth-muted">
        {ngettext("%{count} salto", "%{count} saltos", @jumps)}
        <span :for={{count, label, class} <- @band_parts}>
          · <span class={class}>{count}</span> {label}
        </span>
      </div>

      <p :if={@alerts != []} class="mt-2 text-xs text-error">
        <.icon name="hero-exclamation-triangle" class="size-3.5" />
        {gettext("En alerta: %{systems}",
          systems: Enum.map_join(@alerts, ", ", &system_name/1)
        )}
      </p>

      <div :if={length(@regions) > 1} class="mt-2 flex flex-wrap gap-1">
        <button
          :for={region_id <- @regions}
          type="button"
          phx-click="map_enter"
          phx-value-id={region_id}
          class="border border-base-300 px-1.5 py-0.5 text-[11px] transition-colors hover:border-primary/60 hover:text-primary"
        >
          {map_region_name(@galaxy, region_id)}
        </button>
      </div>
    </section>
    """
  end

  ## Inspector del mapa (RF-8.2)

  attr :galaxy, :map, required: true
  attr :regions, :map, required: true
  attr :heat, :map, required: true
  attr :opps, :map, required: true
  attr :pilots, :map, required: true, doc: "pilotos por sistema"

  # Universo: totales, dónde están los pilotos y las regiones que más se destacan.
  defp map_universe_panel(assigns) do
    heat = Map.values(assigns.heat)

    assigns =
      assign(assigns,
        alerts: heat |> Enum.map(& &1.alerts) |> Enum.sum(),
        kills: heat |> Enum.map(& &1.kills) |> Enum.sum(),
        opp_total: assigns.opps.regions |> Map.values() |> Enum.map(& &1.buy) |> Enum.sum(),
        top_opps: top_regions(assigns.opps.regions, & &1.buy, 5),
        top_heat: top_regions(assigns.heat, &(&1.alerts * 1_000 + &1.kills), 5)
      )

    ~H"""
    <div id="map-universe-panel" class="space-y-4">
      <h3 class="eth-kicker text-[11px] text-primary">{gettext("Universo")}</h3>
      <div class="grid grid-cols-2 gap-3">
        <.stat
          label={gettext("regiones con poller")}
          value={"#{map_size(@regions)} / #{length(@galaxy.nodes)}"}
        />
        <.stat label={gettext("oportunidades")} value={Format.integer(@opp_total)} />
        <.stat
          label={gettext("sistemas en alerta")}
          value={Format.integer(@alerts)}
          value_class={@alerts > 0 && "text-error"}
        />
        <.stat label={gettext("kills en la ventana")} value={Format.integer(@kills)} />
      </div>

      <.map_list id="map-pilots" title={gettext("Pilotos")}>
        <li :if={@pilots == %{}} class="px-2 py-1.5 text-xs eth-faint">
          {gettext("Ningún personaje con ubicación: iniciá sesión con uno para verlo acá.")}
        </li>
        <li :for={{system_id, names} <- @pilots}>
          <button
            type="button"
            id={"map-pilot-#{system_id}"}
            phx-click="map_pilot"
            phx-value-id={system_id}
            class="flex w-full items-center gap-2 px-2 py-1.5 text-left text-sm transition-colors hover:bg-base-200"
          >
            <span class="inline-block size-2 rotate-45 bg-accent"></span>
            <span class="min-w-0 flex-1 truncate">{Enum.join(names, ", ")}</span>
            <span class="font-mono text-xs" style={sec_style(system_id)}>
              {system_name(system_id)}
            </span>
          </button>
        </li>
      </.map_list>

      <.map_list
        :if={@top_opps != []}
        id="map-top-opps"
        title={gettext("Más oportunidades (compran ahí)")}
      >
        <li :for={{region_id, count} <- @top_opps}>
          <.map_list_button id={"map-top-opps-#{region_id}"} event="map_enter" value={region_id}>
            {map_region_name(@galaxy, region_id)}
            <:detail>
              <span class="text-success">{Format.integer(count)}</span>
              <span class="eth-faint">· {Format.compact(@opps.regions[region_id].best)}</span>
            </:detail>
          </.map_list_button>
        </li>
      </.map_list>

      <.map_list :if={@top_heat != []} id="map-top-heat" title={gettext("Más calientes")}>
        <li :for={{region_id, _score} <- @top_heat}>
          <.map_list_button id={"map-top-heat-#{region_id}"} event="map_enter" value={region_id}>
            {map_region_name(@galaxy, region_id)}
            <:detail>
              <span class={heat_tone(@heat[region_id])}>
                {heat_text(@heat[region_id])}
              </span>
            </:detail>
          </.map_list_button>
        </li>
      </.map_list>
    </div>
    """
  end

  attr :region_id, :integer, required: true
  attr :name, :string, required: true
  attr :map, :map, required: true, doc: "`Eth.Sde.region_map/1`"
  attr :status, :map, default: nil
  attr :heat, :map, default: nil
  attr :opps, :map, required: true
  attr :hot_index, :map, required: true
  attr :system_heat, :map, required: true
  attr :pilots, :map, required: true, doc: "pilotos por sistema (de todo el universo)"
  attr :system, :integer, default: nil
  attr :now, :any, required: true

  # Región: totales, la ficha del sistema elegido, sus sistemas calientes y sus salidas.
  defp map_region_panel(assigns) do
    %{map: map, opps: opps} = assigns
    ids = MapSet.new(map.nodes, & &1.id)
    region_opps = opps.regions[assigns.region_id]

    assigns =
      assign(assigns,
        stations: map.nodes |> Enum.map(& &1.stations) |> Enum.sum(),
        region_opps: region_opps,
        hot:
          assigns.hot_index
          |> Map.values()
          |> Enum.filter(&MapSet.member?(ids, &1.system_id))
          |> Enum.sort_by(&{not &1.alert, -&1.kills})
          |> Enum.take(5),
        exits: map.nodes |> Enum.flat_map(& &1.exits) |> Enum.uniq() |> Enum.sort_by(& &1.name),
        node: assigns.system && Enum.find(map.nodes, &(&1.id == assigns.system)),
        status_label: assigns.status && elem(display(assigns.status, assigns.now), 1)
      )

    ~H"""
    <div id="map-region-inspector" class="space-y-4">
      <div class="flex items-baseline justify-between gap-2">
        <h3 class="eth-kicker text-[11px] text-primary">{@name}</h3>
        <span :if={@status_label} class="text-xs eth-muted">{@status_label}</span>
      </div>
      <div class="grid grid-cols-2 gap-3">
        <.stat label={gettext("sistemas")} value={Format.integer(length(@map.nodes))} />
        <.stat label={gettext("estaciones NPC")} value={Format.integer(@stations)} />
        <.stat
          label={gettext("oportunidades (compran · venden)")}
          value={
            if(@region_opps,
              do: "#{Format.integer(@region_opps.buy)} · #{Format.integer(@region_opps.sell)}",
              else: "0"
            )
          }
        />
        <.stat
          label={gettext("en alerta · kills")}
          value={if(@heat, do: "#{@heat.alerts} · #{@heat.kills}", else: "0 · 0")}
          value_class={@heat && @heat.alerts > 0 && "text-error"}
        />
      </div>
      <.link
        id="map-region-hunter"
        navigate={~p"/?#{[search: @name]}"}
        class="btn btn-ghost btn-xs border-base-300"
      >
        <.icon name="hero-magnifying-glass" class="size-3.5" />
        {gettext("Contratos de %{name} en el Cazador", name: @name)}
      </.link>

      <.map_system_card
        :if={@node}
        node={@node}
        hot={@hot_index[@node.id]}
        opps={@opps.systems[@node.id]}
        pilots={@pilots}
      />

      <.map_list :if={@hot != []} id="map-region-hot" title={gettext("Sistemas calientes")}>
        <li :for={h <- @hot}>
          <.map_list_button
            id={"map-region-hot-#{h.system_id}"}
            event="map_system"
            value={h.system_id}
            focus
          >
            {system_name(h.system_id)}
            <:detail>
              <span class={if(h.alert, do: "text-error", else: "text-warning")}>
                {heat_text(@system_heat[h.system_id])}
              </span>
            </:detail>
          </.map_list_button>
        </li>
      </.map_list>

      <div :if={@exits != []} id="map-region-exits">
        <h4 class="eth-kicker mb-1.5 text-[10px]">{gettext("Regiones vecinas")}</h4>
        <div class="flex flex-wrap gap-1">
          <button
            :for={exit <- @exits}
            type="button"
            id={"map-exit-#{exit.id}"}
            phx-click="map_enter"
            phx-value-id={exit.id}
            class="border border-info/40 px-1.5 py-0.5 text-xs text-info transition-colors hover:bg-info/10"
          >
            → {exit.name}
          </button>
        </div>
      </div>
    </div>
    """
  end

  attr :node, :map, required: true
  attr :hot, :map, default: nil, doc: "entrada del radar (`Eth.Threat.hot_systems/0`)"
  attr :opps, :map, default: nil
  attr :pilots, :map, required: true

  # Ficha de un sistema: seguridad, estaciones, salidas, radar, oportunidades y a cuántos
  # saltos está cada piloto.
  defp map_system_card(assigns) do
    assigns = assign(assigns, :jumps, pilot_jumps(assigns.pilots, assigns.node.id))

    ~H"""
    <section
      id="map-system-card"
      class="eth-chamfer-sm border border-primary/40 bg-base-200/50 p-3"
    >
      <div class="flex items-start justify-between gap-2">
        <div>
          <div class="font-display text-base eth-strong">{@node.name}</div>
          <div class="text-xs eth-muted">
            <span class="font-mono" style={"color: #{Sde.security_color(@node.security)}"}>
              {security_text(@node.security)}
            </span>
            · {ngettext("%{count} estación NPC", "%{count} estaciones NPC", @node.stations)}
          </div>
        </div>
        <button
          type="button"
          id="map-system-close"
          phx-click="map_system_close"
          aria-label={gettext("Cerrar la ficha del sistema")}
          class="eth-muted transition-colors hover:text-primary"
        >
          <.icon name="hero-x-mark" class="size-4" />
        </button>
      </div>

      <dl class="mt-3 space-y-2 text-sm">
        <div :if={@node.exits != []}>
          <dt class="text-xs eth-faint">{gettext("Sale por stargate a")}</dt>
          <dd class="mt-0.5 flex flex-wrap gap-1">
            <button
              :for={exit <- @node.exits}
              type="button"
              phx-click="map_enter"
              phx-value-id={exit.id}
              class="border border-info/40 px-1.5 py-0.5 text-xs text-info transition-colors hover:bg-info/10"
            >
              → {exit.name}
            </button>
          </dd>
        </div>
        <div>
          <dt class="text-xs eth-faint">{gettext("Radar")}</dt>
          <dd :if={is_nil(@hot)} class="eth-muted">{gettext("Sin kills en la ventana")}</dd>
          <dd :if={@hot} class={if(@hot.alert, do: "text-error", else: "text-warning")}>
            {ngettext("%{count} kill", "%{count} kills", @hot.kills)}
            <span class="eth-faint">
              · {gettext("%{times}× lo normal", times: over_normal(@hot))}
            </span>
            <span
              :if={@hot[:trend] in [:rising, :falling]}
              class={["ml-1", trend_class(@hot.trend)]}
              title={trend_label(@hot.trend)}
            >
              {if @hot.trend == :rising, do: "▲", else: "▼"}
            </span>
          </dd>
          <dd :if={@hot && @hot.alert && @hot.classification} class="mt-1 text-xs eth-muted">
            <span class="font-semibold text-error">
              {threat_type_label(@hot.classification.type)}:
            </span>
            {@hot.classification.description}
          </dd>
        </div>
        <div>
          <dt class="text-xs eth-faint">{gettext("Oportunidades")}</dt>
          <dd :if={is_nil(@opps)} class="eth-muted">{gettext("Ninguna compra ni vende acá")}</dd>
          <dd :if={@opps}>
            <span class="text-success">
              {ngettext("%{count} compra", "%{count} compran", @opps.buy)}
            </span>
            · {ngettext("%{count} vende", "%{count} venden", @opps.sell)}
            <span class="eth-faint">
              · {gettext("mejor %{isk} ISK", isk: Format.compact(@opps.best))}
            </span>
          </dd>
        </div>
        <div :if={@jumps != []}>
          <dt class="text-xs eth-faint">{gettext("Pilotos (ruta corta · segura)")}</dt>
          <dd :for={j <- @jumps} class="flex items-baseline justify-between gap-2">
            <span class="truncate">{j.name}</span>
            <span :if={j.here?} class="text-accent">{gettext("está acá")}</span>
            <span :if={not j.here?} class="font-mono text-xs tabular-nums eth-muted">
              {jumps_text(j.shortest)} · {jumps_text(j.secure)}
            </span>
          </dd>
        </div>
      </dl>

      <.link
        id="map-system-hunter"
        navigate={~p"/?#{[search: @node.name]}"}
        class="btn btn-ghost btn-xs mt-3 border-base-300"
      >
        <.icon name="hero-magnifying-glass" class="size-3.5" />
        {gettext("Contratos en %{name}", name: @node.name)}
      </.link>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :rest, :global
  slot :inner_block, required: true

  defp map_list(assigns) do
    ~H"""
    <div id={@id} {@rest}>
      <h4 class="eth-kicker mb-1.5 text-[10px]">{@title}</h4>
      <ul class="divide-y divide-base-300/60 border border-base-300">
        {render_slot(@inner_block)}
      </ul>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :event, :string, required: true
  attr :value, :any, required: true
  attr :focus, :boolean, default: false
  slot :inner_block, required: true
  slot :detail

  defp map_list_button(assigns) do
    ~H"""
    <button
      type="button"
      id={@id}
      phx-click={@event}
      phx-value-id={@value}
      phx-value-focus={@focus && "1"}
      class="flex w-full items-baseline justify-between gap-2 px-2 py-1.5 text-left text-sm transition-colors hover:bg-base-200"
    >
      <span class="min-w-0 truncate">{render_slot(@inner_block)}</span>
      <span class="shrink-0 text-xs tabular-nums">{render_slot(@detail)}</span>
    </button>
    """
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
