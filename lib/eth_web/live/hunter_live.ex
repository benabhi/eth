defmodule EthWeb.HunterLive do
  @moduledoc """
  Cazador de trades: pantalla principal (ERS §9.3).

  - Filtros en un formulario cuyo estado vive en la URL (recarga y marcadores conservan
    la vista, RF-6.4).
  - Grilla densa con stream (máx. 200 filas), orden del lado del servidor (RF-6.2).
  - Actualización en vivo por `engine:opportunities`; con **Congelar** las versiones nuevas
    quedan pendientes hasta aplicarlas (RF-6.3).
  - Panel de detalle con el desglose del cálculo, el libro consumido y el "¿por qué?" del
    TVS y la Certeza (RF-6.5), y exportación Multibuy (RF-6.6).

  - Con un piloto activo (F4), Accounting, capital, bodega, clase de nave y sistema de
    partida salen de su contexto en vivo (RF-5.5 a RF-5.8); los filtros siguen pudiendo
    sobrescribirlos. En modo invitado se cargan a mano.
  - Acciones in-game (RF-5.9, RF-6.7): fijar ruta y abrir mercado, solo por clic.
  - Anti-scam (RF-4.8): insignias con el estado, SCAM oculto por defecto, motivos en el
    detalle, Multibuy y Ruta bloqueados en una SCAM y "Reportar falso positivo".
  - Historial (RF-1.12, RF-6.5): sparkline de 30 días, mediana, volumen y liquidez; las
    estadísticas nuevas se reflejan en vivo (`market:history`).
  - Diseño F10 (§9.5): rango por TVS, sellos, medidor de peligro, anillo de Certeza y "?"
    con enlace al manual; filtros acoplados a la tabla.
  - La ficha se despliega bajo la fila (RF-6.5): una sola abierta, se cierra con otro
    clic, `Esc` o al abrir otra; mientras está abierta la grilla se congela y los cambios
    quedan pendientes. La ruta con el radar se calcula en segundo plano con un spinner
    (RNF-5.15).

  Implementa: RF-4.7, RF-4.8, RF-5.9, RF-6.2, RF-6.3, RF-6.4, RF-6.5, RF-6.6, RF-6.7,
  RF-6.10, RF-11.2, RNF-5.15.
  """
  use EthWeb, :live_view

  import EthWeb.TradingComponents

  alias Eth.{Characters, Clock, Engine, Market, Sde, Tracking}
  alias Eth.Characters.Pilot
  alias Eth.Engine.{Grade, Query}
  alias EthWeb.{Format, HunterParams, RowChanges}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Eth.PubSub, Engine.topic())
      Phoenix.PubSub.subscribe(Eth.PubSub, Market.history_topic())
    end

    socket =
      socket
      |> assign(:page_title, gettext("Cazador de trades"))
      |> assign(:frozen, false)
      |> assign(:pending, 0)
      |> assign(:selected, nil)
      |> assign(:route_details, nil)
      |> assign(:route_loading, false)
      |> assign(skill_gains: [], book_depth: nil)
      |> assign(:total, 0)
      |> assign(known: nil, highlights: %{}, lingering: %{}, ghosts: %{}, hovering: false)
      |> assign(:reward, 0.0)
      |> assign(:meta, Engine.meta())
      |> assign(:now, Clock.utc_now())
      |> assign(:url_params, %{})
      |> assign(:pilot_overrides, pilot_overrides(socket.assigns.pilot))
      |> stream_configure(:rows, dom_id: &"opp-#{&1.id}")
      |> stream(:rows, [])

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:url_params, Map.take(params, HunterParams.fields()))
     |> apply_filters()
     |> load_rows()}
  end

  @impl true
  def handle_event("filter", %{"filters" => filters}, socket) do
    url_params = HunterParams.to_url_params(filters, socket.assigns.form_defaults)
    {:noreply, push_patch(socket, to: ~p"/?#{url_params}")}
  end

  def handle_event("reset_filters", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/")}
  end

  # Clic en una fila: abre su ficha debajo, o la cierra si ya estaba abierta (RF-6.5).
  def handle_event("select", %{"id" => id}, socket) do
    if socket.assigns.selected == id,
      do: {:noreply, close_detail(socket)},
      else: {:noreply, open_detail(socket, id)}
  end

  def handle_event("close_detail", _params, socket), do: {:noreply, close_detail(socket)}

  def handle_event("toggle_freeze", _params, socket) do
    if socket.assigns.frozen do
      {:noreply, socket |> assign(frozen: false, pending: 0) |> load_rows()}
    else
      {:noreply, assign(socket, :frozen, true)}
    end
  end

  # Puntero sobre la grilla (RF-6.3): congela; al salir se aplica lo pendiente.
  def handle_event("hover_hold", %{"on" => on}, socket) do
    socket = assign(socket, :hovering, on == true)

    if not held?(socket) and socket.assigns.pending > 0,
      do: {:noreply, socket |> assign(:pending, 0) |> load_rows()},
      else: {:noreply, socket}
  end

  def handle_event("copied", _params, socket) do
    {:noreply, put_flash(socket, :info, gettext("Multibuy copiado al portapapeles"))}
  end

  # Iniciar viaje (RF-7.1): congela el plan de la fila seleccionada y lleva a /run.
  def handle_event("start_run", _params, socket) do
    with %{} = row <- socket.assigns.selected_row,
         %{} = pilot <- socket.assigns.pilot,
         nil <- start_run_blocked(pilot, row) do
      case Tracking.start(pilot.id, row, socket.assigns.query) do
        {:ok, _run} ->
          {:noreply,
           socket
           |> put_flash(:info, gettext("Viaje iniciado: fijá la ruta desde Viaje activo"))
           |> push_navigate(to: ~p"/run")}

        {:error, :already_active} ->
          {:noreply,
           put_flash(socket, :error, gettext("Ya tenés un viaje en curso: terminalo o abortalo"))}
      end
    else
      reason when is_binary(reason) -> {:noreply, put_flash(socket, :error, reason)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("report_false_positive", _params, socket) do
    with %{} = row <- socket.assigns.selected_row,
         true <- row.shield.status in [:scam, :suspicious],
         {:ok, _report} <- Engine.report_false_positive(row) do
      {:noreply,
       put_flash(
         socket,
         :info,
         gettext("Falso positivo registrado: sirve para calibrar el escudo")
       )}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("No se pudo registrar el reporte"))}
    end
  end

  # Una oportunidad SCAM tiene las acciones bloqueadas (RF-4.8); se verifica también acá,
  # no solo deshabilitando el botón.
  def handle_event("set_route", _params, socket) do
    with %{} = row <- socket.assigns.selected_row,
         false <- scam?(row),
         %{} = pilot <- socket.assigns.pilot,
         nil <- action_blocked(pilot, :waypoint) do
      opp = row.opportunity
      at_origin? = Pilot.at_location?(pilot, opp.origin.location_id)

      {:noreply,
       start_async(socket, :ingame, fn ->
         {:route,
          Characters.set_route(
            pilot.id,
            opp.origin.location_id,
            opp.destination.location_id,
            at_origin?
          )}
       end)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("open_market", _params, socket) do
    with %{} = row <- socket.assigns.selected_row,
         %{} = pilot <- socket.assigns.pilot,
         nil <- action_blocked(pilot, :market) do
      type_id = row.opportunity.type_id

      {:noreply,
       start_async(socket, :ingame, fn ->
         {:market, Characters.open_market(pilot.id, type_id)}
       end)}
    else
      _ -> {:noreply, socket}
    end
  end

  @impl true
  def handle_async(:route, {:ok, {id, route}}, %{assigns: %{selected: id}} = socket) do
    {:noreply,
     socket
     |> assign(route_details: route, route_loading: false)
     |> reinsert_selected()}
  end

  # Resultado de una ficha anterior: ya se abrió otra o se cerró.
  def handle_async(:route, {:ok, _stale}, socket), do: {:noreply, socket}

  def handle_async(:route, {:exit, _reason}, socket) do
    {:noreply,
     socket
     |> assign(route_loading: false)
     |> reinsert_selected()
     |> put_flash(:error, gettext("No se pudo calcular la ruta del contrato"))}
  end

  def handle_async(:ingame, {:ok, {action, :ok}}, socket) do
    message =
      case action do
        :route -> gettext("Ruta fijada en el juego")
        :market -> gettext("Mercado abierto en el juego")
      end

    {:noreply, put_flash(socket, :info, message)}
  end

  def handle_async(:ingame, {:ok, {_action, {:error, reason}}}, socket) do
    {:noreply, put_flash(socket, :error, ingame_error(reason))}
  end

  def handle_async(:ingame, {:exit, _reason}, socket) do
    {:noreply, put_flash(socket, :error, gettext("La acción in-game falló"))}
  end

  @impl true
  def handle_info({:opportunities_updated, _meta}, socket), do: {:noreply, refresh(socket)}

  # Estadísticas de historial nuevas (RF-1.12): cambian anti-scam, liquidez y TVS.
  def handle_info({:history_updated, _count}, socket), do: {:noreply, refresh(socket)}

  # Cambió el mapa de calor (RF-3.3): cambian el riesgo de ruta, la Certeza y el TVS.
  # `EthWeb.RadarHook` ya actualizó la cabecera.
  def handle_info({:heatmap, _version}, socket), do: {:noreply, refresh(socket)}

  # `EthWeb.PilotHook` ya actualizó @pilot; solo se recalcula si cambió lo que usa el motor.
  def handle_info({:character, _id, _event, _public}, socket) do
    overrides = pilot_overrides(socket.assigns.pilot)

    cond do
      overrides == socket.assigns.pilot_overrides ->
        {:noreply, socket}

      held?(socket) ->
        {:noreply,
         socket
         |> assign(:pilot_overrides, overrides)
         |> apply_filters()
         |> update(:pending, &(&1 + 1))}

      true ->
        {:noreply,
         socket |> assign(:pilot_overrides, overrides) |> apply_filters() |> load_rows()}
    end
  end

  # Las filas expiradas salen después de mostrarse tachadas (RF-6.3); si una volvió en
  # la última carga, se queda.
  def handle_info({:drop_expired, ids}, socket) do
    {:noreply,
     Enum.reduce(ids, socket, fn id, acc ->
       if Map.has_key?(acc.assigns.ghosts, id),
         do: acc,
         else:
           acc
           |> update(:lingering, &Map.delete(&1, id))
           |> stream_delete_by_dom_id(:rows, "opp-#{id}")
     end)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # Con la grilla congelada, una ficha abierta o el puntero sobre la grilla, los cambios
  # quedan pendientes (RF-6.3).
  defp held?(socket),
    do: socket.assigns.frozen or socket.assigns.selected != nil or socket.assigns.hovering

  defp refresh(socket) do
    if held?(socket), do: update(socket, :pending, &(&1 + 1)), else: load_rows(socket)
  end

  ## Ficha bajo la fila (RF-6.5)

  # La fila se reinserta en el stream para que se dibuje abierta; la anterior, cerrada.
  # La personalización es rápida; la ruta con el radar va en segundo plano.
  defp open_detail(socket, id) do
    query = socket.assigns.query

    case selected_row(id, query) do
      nil ->
        socket

      row ->
        previous = socket.assigns.selected_row

        socket
        |> assign(selected: id, selected_row: row, route_details: nil, route_loading: true)
        |> assign_detail_extras()
        |> reinsert(previous)
        |> stream_insert(:rows, row)
        |> start_async(:route, fn -> {id, route_details(row, query)} end)
    end
  end

  # Al cerrar se aplican los cambios que quedaron pendientes mientras estaba abierta.
  defp close_detail(%{assigns: %{selected: nil}} = socket), do: socket

  defp close_detail(socket) do
    previous = socket.assigns.selected_row

    socket =
      socket
      |> assign(selected: nil, selected_row: nil, route_details: nil, route_loading: false)
      |> assign_detail_extras()
      |> reinsert(previous)

    if socket.assigns.pending > 0 and not socket.assigns.frozen,
      do: socket |> assign(:pending, 0) |> load_rows(),
      else: socket
  end

  # Habilidades y libro siguiente de la ficha abierta (RF-6.15, RF-6.16). Se recalculan
  # con la fila: cambian con el mercado y con los filtros (Accounting, capital, bodega).
  defp assign_detail_extras(%{assigns: %{selected_row: nil}} = socket),
    do: assign(socket, skill_gains: [], book_depth: nil)

  defp assign_detail_extras(%{assigns: %{selected_row: row, query: query}} = socket) do
    assign(socket,
      skill_gains: Engine.skill_gains(:direct, row.opportunity, query),
      book_depth: Engine.book_depth(row, query)
    )
  end

  # Beneficio sin la mejor compra frente al actual (RF-6.16): verde si conserva casi todo,
  # ámbar si se resiente, rojo si se pierde.
  defp fallback_class(nil, _row), do: "text-error"

  defp fallback_class(%{profit: profit}, row) do
    cond do
      profit >= row.profit * 0.8 -> "text-success"
      profit > 0 -> "text-warning"
      true -> "text-error"
    end
  end

  defp fallback_change(%{profit: profit}, row) do
    change = round((profit - row.profit) / row.profit * 100)
    if change >= 0, do: "+#{change} %", else: "−#{abs(change)} %"
  end

  defp reinsert_selected(socket), do: reinsert(socket, socket.assigns.selected_row)

  defp reinsert(socket, nil), do: socket
  defp reinsert(socket, row), do: stream_insert(socket, :rows, row)

  # Defaults del formulario = modo invitado + datos del piloto; la URL tiene prioridad.
  defp apply_filters(socket) do
    overrides = socket.assigns.pilot_overrides
    defaults = HunterParams.form_defaults(overrides)
    form = Map.merge(defaults, socket.assigns.url_params)

    query =
      form
      |> HunterParams.to_query()
      |> Map.merge(Map.take(overrides, [:base_system_id, :ship_class, :character_id]))

    # Filtros o piloto nuevos: la tabla siguiente no se compara con la anterior (RF-6.3).
    socket
    |> assign(:known, nil)
    |> assign(:form_defaults, defaults)
    |> assign(:form, to_form(form, as: :filters))
    |> assign(:query, query)
  end

  defp pilot_overrides(nil), do: %{}
  defp pilot_overrides(pilot), do: Pilot.query_overrides(pilot)

  defp load_rows(socket) do
    {rows, total} = Engine.query(socket.assigns.query)
    previous = socket.assigns.known && socket.assigns.ghosts
    {flashes, known} = RowChanges.diff(socket.assigns.known, rows, &{&1.profit, &1.tvs})
    flashes = RowChanges.with_moved(flashes, previous, rows)
    # Resaltados y tachadas duran por tiempo, no por recarga (RF-6.3).
    now_ms = System.monotonic_time(:millisecond)
    highlights = RowChanges.highlights(previous && socket.assigns.highlights, flashes, now_ms)

    {shown, lingering, expired} =
      RowChanges.with_lingering(rows, previous, socket.assigns.lingering, now_ms)

    if expired != [],
      do: Process.send_after(self(), {:drop_expired, expired}, RowChanges.expire_ms())

    socket
    |> assign(highlights: highlights, lingering: lingering, known: known)
    |> assign(:ghosts, RowChanges.ghosts(rows, &ghost/1))
    |> assign(total: total, meta: Engine.meta(), now: Clock.utc_now(), empty?: rows == [])
    |> assign(:reward, Enum.reduce(rows, 0.0, &(&1.profit + &2)))
    |> assign(:selected_row, selected_row(socket.assigns[:selected], socket.assigns.query))
    |> assign_detail_extras()
    |> assign_route_details()
    |> stream(:rows, shown, reset: true)
  end

  defp ghost(row) do
    opp = row.opportunity
    %{name: opp.type_name, detail: "#{opp.origin.name} → #{opp.destination.name}"}
  end

  # La fila seleccionada se recalcula aparte: puede no estar entre las 200 visibles.
  # Detalle de la ruta de la fila seleccionada (sección Ruta, RF-6.5).
  defp assign_route_details(%{assigns: %{selected_row: row, query: query}} = socket) do
    assign(socket, :route_details, route_details(row, query))
  end

  defp route_details(nil, _query), do: nil

  defp route_details(row, query) do
    ship_class = Map.get(query, :ship_class, Query.defaults().ship_class)
    Engine.route_details(row, ship_class)
  end

  defp selected_row(nil, _query), do: nil

  defp selected_row(id, query) do
    case Engine.get(id) do
      nil -> nil
      opp -> Query.personalize(opp, Map.merge(Query.defaults(), query), Clock.utc_now())
    end
  end

  # Columnas de la grilla, iguales en el encabezado y en cada fila; las ocultas en
  # pantallas chicas no ocupan pista (RNF-5.9).
  @grid "grid items-center gap-x-2.5 px-3 sm:gap-x-4 sm:px-4 grid-cols-[2.5rem_minmax(0,1fr)_6.5rem_2.75rem] md:grid-cols-[4.5rem_minmax(0,1.2fr)_minmax(0,1.4fr)_7.75rem_6.5rem_5.75rem_1.25rem] lg:grid-cols-[4.5rem_minmax(0,1.2fr)_minmax(0,1.4fr)_7.5rem_8rem_6.5rem_5.75rem_1.25rem]"

  defp grid_class, do: @grid

  ## Acciones in-game (RF-6.7)

  @scopes %{waypoint: "esi-ui.write_waypoint.v1", market: "esi-ui.open_window.v1"}

  # Motivo por el que una acción in-game no está disponible (`nil` si lo está).
  defp action_blocked(nil, _action),
    do: gettext("Iniciá sesión con EVE para usar las acciones in-game")

  defp action_blocked(pilot, action) do
    cond do
      not Pilot.scope?(pilot, @scopes[action]) ->
        gettext("Falta el permiso %{scope}: volvé a iniciar sesión", scope: @scopes[action])

      pilot.status != :ok ->
        gettext("La sesión de EVE del personaje no está lista")

      pilot.online == false ->
        gettext("El personaje no está conectado al juego")

      true ->
        nil
    end
  end

  # Motivo por el que no se puede iniciar un viaje con esta fila (`nil` si se puede).
  defp start_run_blocked(nil, _row), do: gettext("Iniciá sesión con EVE para seguir un viaje")
  defp start_run_blocked(_pilot, %{shield: %{status: :scam}}), do: gettext("Bloqueado: SCAM")

  defp start_run_blocked(pilot, _row) do
    if Tracking.active(pilot.id), do: gettext("Ya tenés un viaje en curso")
  end

  defp ingame_error(:relogin),
    do: gettext("La autorización de EVE venció: volvé a iniciar sesión")

  defp ingame_error({:http, %{status: 403}}),
    do: gettext("EVE rechazó la acción: falta el permiso o el personaje no está conectado")

  defp ingame_error({:http, %{status: status}}),
    do: gettext("EVE rechazó la acción (HTTP %{status})", status: status)

  defp ingame_error({reason, _until}) when reason in [:paused, :rate_limited],
    do: gettext("ESI está en pausa: probá de nuevo en unos segundos")

  defp ingame_error(_reason), do: gettext("La sesión de EVE del personaje no está lista")

  ## Presentación

  @doc false
  # Línea Multibuy por objeto: `Nombre<TAB>Cantidad` (RF-6.6). El TAB evita la ambigüedad
  # con nombres que terminan en número ("Navy Cap Booster 400").
  @spec multibuy(map()) :: String.t()
  def multibuy(row), do: "#{row.opportunity.type_name}\t#{row.quantity}"

  ## Anti-scam e historial (RF-4.7, RF-4.8, RF-6.5)

  defp scam?(row), do: row.shield.status == :scam

  ## Acceso a estructuras (RF-1.6, AS-8)

  @access_order [:forbidden, :private_unverified, :public, :private_ok, :npc]

  defp worst_access(access) do
    Enum.min_by(
      [access.origin, access.destination],
      &Enum.find_index(@access_order, fn a -> a == &1 end)
    )
  end

  defp access_label(:forbidden), do: gettext("estructura · sin acceso")
  defp access_label(:private_unverified), do: gettext("estructura · sin verificar")
  defp access_label(:private_ok), do: gettext("estructura privada ✓")
  defp access_label(_public), do: gettext("estructura")

  defp access_title(access) do
    gettext("Origen: %{origin} · destino: %{destination}",
      origin: access_name(access.origin),
      destination: access_name(access.destination)
    )
  end

  defp access_name(:npc), do: gettext("estación NPC")
  defp access_name(:public), do: gettext("estructura pública")
  defp access_name(:private_ok), do: gettext("privada con acceso verificado")
  defp access_name(:private_unverified), do: gettext("privada sin acceso verificado")
  defp access_name(:forbidden), do: gettext("sin acceso para este personaje (403)")

  defp threat_label(:gate_camp), do: gettext("Gatecamp")
  defp threat_label(:bubble_camp), do: gettext("Bubble camp")
  defp threat_label(:smartbomb_camp), do: gettext("Smartbombs")
  defp threat_label(:hauler_gank), do: gettext("Gank de transportes")
  defp threat_label(:roaming), do: gettext("Actividad hostil")

  # Sello de amenaza en la ruta: tipo y sistema de la peor (que no parezca del origen), más
  # la cantidad de las demás.
  defp threat_seal(%{count: count, worst: worst}) do
    system = (Sde.system(worst.system_id) || %{name: "?"}).name
    label = "#{threat_label(worst.classification.type)} · #{system}"
    if count > 1, do: "#{label} +#{count - 1}", else: label
  end

  @doc false
  # Puntos `"x,y x,y …"` de un sparkline SVG (viewBox 0 0 120 32) con los promedios
  # diarios: une los días con operaciones, cada uno en su posición del calendario. `nil`
  # si no hubo ninguno; un único día se dibuja como un trazo corto.
  @spec sparkline([float() | nil]) :: String.t() | nil
  def sparkline(values) do
    points =
      values
      |> Enum.with_index()
      |> Enum.reject(fn {value, _i} -> is_nil(value) end)

    case points do
      [] ->
        nil

      [{_value, i}] ->
        x = i * 120 / max(length(values) - 1, 1)
        "#{Float.round(max(x - 2, 0.0), 1)},16 #{Float.round(min(x + 2, 120.0), 1)},16"

      _many ->
        {low, high} = points |> Enum.map(&elem(&1, 0)) |> Enum.min_max()
        span = if high - low > 0, do: high - low, else: 1.0
        step = 120 / max(length(values) - 1, 1)

        Enum.map_join(points, " ", fn {value, i} ->
          "#{Float.round(i * step, 1)},#{Float.round(30 - (value - low) / span * 28, 1)}"
        end)
    end
  end

  defp sec_style(nil), do: ""
  defp sec_style(sec), do: "color: #{Sde.security_color(sec)}"

  # Tramo de la tira de seguridad de la ruta (mismo color que el número de seguridad).
  defp sec_background(nil), do: "background-color: var(--color-base-300)"
  defp sec_background(sec), do: "background-color: #{Sde.security_color(sec)}"

  # Factores de la Certeza para la franja "¿Por qué TVS?" (RF-6.5), con su etiqueta.
  defp certainty_factors(row, radar_degraded?) do
    b = row.breakdown

    route_label =
      if radar_degraded?,
        do: gettext("Ruta (amenazas y riesgo base) · radar degradado"),
        else: gettext("Ruta (amenazas y riesgo base)")

    liquidity_label =
      if row.history.destination,
        do: gettext("Liquidez"),
        else: gettext("Liquidez (neutra hasta tener historial)")

    [
      {gettext("Órdenes vigentes al llegar"), b.order_certainty},
      {gettext("Frescura de datos"), b.data_certainty},
      {gettext("Anti-scam (%{status})", status: shield_label(row.shield.status)),
       b.scam_certainty},
      {gettext("Acceso"), b.access_certainty},
      {route_label, b.route_certainty},
      {liquidity_label, b.liquidity}
    ]
  end

  # Barra de un factor: atenuada si está entero, ámbar si pesa en contra.
  defp factor_class(value) when value >= 0.95, do: "bg-primary/50"
  defp factor_class(value) when value >= 0.7, do: "bg-primary"
  defp factor_class(_value), do: "bg-warning"

  defp sec_label(nil), do: "?"
  defp sec_label(sec), do: :erlang.float_to_binary(Sde.security_display(sec), decimals: 1)

  defp pct(x), do: "#{:erlang.float_to_binary(x * 100, decimals: 1)} %"

  # Mapa del Centro de control con la ruta de la ficha (RF-8.2): todos los sistemas del
  # camino y el de compra marcado.
  defp route_map_path(details, row) do
    route = Enum.map_join(details.to_origin ++ tl(details.route), ",", & &1.system_id)
    stop = row.opportunity.origin.system_id
    ~p"/control/market?#{[view: "map", route: route, stop: stop]}"
  end

  defp route_label(:secure), do: gettext("Segura")
  defp route_label(:evasive), do: gettext("Evasiva")
  defp route_label(_shortest), do: gettext("Rápida")
end
