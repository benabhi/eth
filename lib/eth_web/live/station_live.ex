defmodule EthWeb.StationLive do
  @moduledoc """
  Station trading en los hubs (RF-4.16, RF-6.12): la familia **Estación** del Cazador.

  - Filtros en la URL (RF-6.4): hub, margen y volumen mínimos, capital, habilidades y
    anti-scam; con un piloto activo, Accounting, Broker Relations, standings y capital
    salen de su contexto en vivo.
  - Grilla con stream (máx. 200 filas): precios sugeridos legales, margen neto, volumen
    diario, beneficio estimado por día, competencia y Certeza.
  - Panel **Mis órdenes** (RF-4.17): las órdenes abiertas del piloto con su estado
    (primera o superada), el precio sugerido para volver a quedar primera y el costo de
    modificarla; sus órdenes no cuentan como competencia.
  - Detalle con el desglose de comisiones, el plan diario, la competencia y el anti-scam,
    "Copiar precio" y "Abrir mercado" (la orden se publica en el cliente: ESI no permite
    crearla, D-12).

  - Diseño F10 (§9.5): cabecera del tablón, filtros acoplados a la tabla, sellos, anillo
    de Certeza, ficha que se despliega bajo la fila (RF-6.5) y anillo de órdenes usadas
    frente al límite.

  Implementa: RF-4.16, RF-4.17, RF-6.4, RF-6.12, RF-6.13, RF-11.2.
  """
  use EthWeb, :live_view

  import EthWeb.TradingComponents

  alias Eth.{Characters, Clock, Engine, Market}
  alias Eth.Characters.Pilot
  alias Eth.Engine.{OwnOrders, StationQuery}
  alias EthWeb.{Format, RowChanges, StationParams}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Eth.PubSub, Engine.topic())
      Phoenix.PubSub.subscribe(Eth.PubSub, Market.history_topic())
    end

    {:ok,
     socket
     |> assign(:page_title, gettext("Station trading"))
     |> assign(:selected, nil)
     |> assign(:selected_row, nil)
     |> assign(:total, 0)
     |> assign(known: nil, highlights: %{}, lingering: %{}, ghosts: %{}, hovering: false)
     |> assign(:pending, 0)
     |> assign(:reward, 0.0)
     |> assign(:url_params, %{})
     |> assign(:hubs, hubs())
     |> assign(:pilot_overrides, overrides(socket.assigns.pilot))
     |> assign_my_orders()
     |> stream_configure(:rows, dom_id: &"st-#{&1.id}")
     |> stream(:rows, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:url_params, Map.take(params, StationParams.fields()))
     |> apply_filters()
     |> load_rows()}
  end

  @impl true
  def handle_event("filter", %{"filters" => filters}, socket) do
    url_params = StationParams.to_url_params(filters, socket.assigns.form_defaults)
    {:noreply, push_patch(socket, to: ~p"/station?#{url_params}")}
  end

  def handle_event("reset_filters", _params, socket),
    do: {:noreply, push_patch(socket, to: ~p"/station")}

  # Clic en una fila: abre su ficha debajo, o la cierra si ya estaba abierta (RF-6.5).
  # Puntero sobre la grilla (RF-6.3): congela; al salir se aplica lo pendiente.
  def handle_event("hover_hold", %{"on" => on}, socket) do
    socket = assign(socket, :hovering, on == true)

    if not held?(socket) and socket.assigns.pending > 0,
      do: {:noreply, socket |> assign(:pending, 0) |> load_rows()},
      else: {:noreply, socket}
  end

  def handle_event("select", %{"id" => id}, socket) do
    if socket.assigns.selected == id,
      do: {:noreply, close_detail(socket)},
      else: {:noreply, open_detail(socket, id)}
  end

  def handle_event("close_detail", _params, socket), do: {:noreply, close_detail(socket)}

  def handle_event("copied", _params, socket),
    do: {:noreply, put_flash(socket, :info, gettext("Precio copiado al portapapeles"))}

  def handle_event("open_market", _params, socket) do
    with %{} = row <- socket.assigns.selected_row,
         %{} = pilot <- socket.assigns.pilot,
         nil <- market_blocked(pilot) do
      type_id = row.opportunity.type_id

      {:noreply,
       start_async(socket, :market, fn -> Characters.open_market(pilot.id, type_id) end)}
    else
      _ -> {:noreply, socket}
    end
  end

  @impl true
  def handle_async(:market, {:ok, :ok}, socket),
    do: {:noreply, put_flash(socket, :info, gettext("Mercado abierto en el juego"))}

  def handle_async(:market, _result, socket),
    do: {:noreply, put_flash(socket, :error, gettext("No se pudo abrir el mercado en el juego"))}

  @impl true
  def handle_info({:opportunities_updated, _meta}, socket), do: {:noreply, refresh(socket)}
  def handle_info({:history_updated, _count}, socket), do: {:noreply, refresh(socket)}

  # `EthWeb.PilotHook` ya actualizó @pilot; solo se recalcula si cambió lo que usa la consulta.
  def handle_info({:character, _id, _event, _public}, socket) do
    new = overrides(socket.assigns.pilot)
    socket = assign_my_orders(socket)

    if new == socket.assigns.pilot_overrides,
      do: {:noreply, socket},
      else: {:noreply, socket |> assign(:pilot_overrides, new) |> apply_filters() |> load_rows()}
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
           |> stream_delete_by_dom_id(:rows, "st-#{id}")
     end)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp overrides(nil), do: %{}
  defp overrides(pilot), do: Pilot.station_overrides(pilot)

  ## Ficha bajo la fila (RF-6.5)

  # Con una ficha abierta o el puntero sobre la grilla, los cambios quedan pendientes
  # (RF-6.3).
  defp held?(socket), do: socket.assigns.selected != nil or socket.assigns.hovering

  defp refresh(socket) do
    if held?(socket), do: update(socket, :pending, &(&1 + 1)), else: load_rows(socket)
  end

  # La fila se reinserta en el stream para que se dibuje abierta; la anterior, cerrada.
  defp open_detail(socket, id) do
    case selected_row(id, socket.assigns.query) do
      nil ->
        socket

      row ->
        previous = socket.assigns.selected_row

        socket
        |> assign(selected: id, selected_row: row)
        |> reinsert(previous)
        |> stream_insert(:rows, row)
    end
  end

  defp close_detail(%{assigns: %{selected: nil}} = socket), do: socket

  defp close_detail(socket) do
    previous = socket.assigns.selected_row
    socket = socket |> assign(selected: nil, selected_row: nil) |> reinsert(previous)

    if socket.assigns.pending > 0 and not held?(socket),
      do: socket |> assign(:pending, 0) |> load_rows(),
      else: socket
  end

  defp reinsert(socket, nil), do: socket
  defp reinsert(socket, row), do: stream_insert(socket, :rows, row)

  # Defaults = modo invitado + piloto; la URL tiene prioridad. Los standings no son un
  # filtro: vienen siempre del piloto.
  defp apply_filters(socket) do
    overrides = socket.assigns.pilot_overrides
    defaults = StationParams.form_defaults(overrides)
    form = Map.merge(defaults, socket.assigns.url_params)

    query =
      form
      |> StationParams.to_query()
      |> Map.merge(Map.take(overrides, [:standings, :own_order_ids]))

    # Filtros o piloto nuevos: la tabla siguiente no se compara con la anterior (RF-6.3).
    socket
    |> assign(:known, nil)
    |> assign(:form_defaults, defaults)
    |> assign(:form, to_form(form, as: :filters))
    |> assign(:query, query)
  end

  defp load_rows(socket) do
    {rows, total} = Engine.station_query(socket.assigns.query)
    previous = socket.assigns.known && socket.assigns.ghosts

    {flashes, known} =
      RowChanges.diff(socket.assigns.known, rows, &{&1.profit_day, round(&1.certainty * 100)})

    flashes = RowChanges.with_moved(flashes, previous, rows)
    # Resaltados y tachadas duran por tiempo, no por recarga (RF-6.3).
    now_ms = System.monotonic_time(:millisecond)
    highlights = RowChanges.highlights(previous && socket.assigns.highlights, flashes, now_ms)

    {shown, lingering, expired} =
      RowChanges.with_lingering(rows, previous, socket.assigns.lingering, now_ms)

    if expired != [],
      do: Process.send_after(self(), {:drop_expired, expired}, RowChanges.expire_ms())

    socket
    |> assign_my_orders()
    |> assign(highlights: highlights, lingering: lingering, known: known)
    |> assign(:ghosts, RowChanges.ghosts(rows, &ghost/1))
    |> assign(total: total, meta: Engine.meta(), now: Clock.utc_now())
    |> assign(:reward, Enum.reduce(rows, 0.0, &(&1.profit_day + &2)))
    |> assign(:selected_row, selected_row(socket.assigns.selected, socket.assigns.query))
    |> stream(:rows, shown, reset: true)
  end

  defp ghost(row), do: %{name: row.opportunity.type_name, detail: row.opportunity.location.name}

  # Órdenes propias del piloto activo con su estado frente al libro vigente (RF-4.17).
  # `nil` si no hay piloto o no concedió el permiso de órdenes.
  defp assign_my_orders(%{assigns: %{pilot: %{orders: orders} = pilot}} = socket)
       when is_list(orders) do
    rows =
      orders
      |> Engine.own_orders(overrides(pilot))
      |> Enum.sort_by(&{&1.status != :outbid, &1.type_name})

    socket
    |> assign(:my_orders, rows)
    |> assign(:my_orders_summary, OwnOrders.summary(orders, pilot.skills || %{}))
  end

  defp assign_my_orders(socket), do: assign(socket, my_orders: nil, my_orders_summary: nil)

  defp selected_row(nil, _query), do: nil

  defp selected_row(id, query) do
    case Engine.station_get(id) do
      nil -> nil
      opp -> StationQuery.personalize(opp, query, Clock.utc_now())
    end
  end

  # Hubs NPC y estructuras con broker propio (RF-9.4).
  defp hubs do
    for {id, name} <- Engine.publish_locations(), do: {name, Integer.to_string(id)}
  end

  defp market_blocked(pilot) do
    cond do
      not Pilot.scope?(pilot, "esi-ui.open_window.v1") ->
        gettext("Falta el permiso esi-ui.open_window.v1: volvé a iniciar sesión")

      pilot.status != :ok ->
        gettext("La sesión de EVE del personaje no está lista")

      pilot.online == false ->
        gettext("El personaje no está conectado al juego")

      true ->
        nil
    end
  end

  ## Presentación

  # Columnas de la grilla, iguales en el encabezado y en cada fila (RNF-5.9).
  @grid "grid items-center gap-x-2.5 px-3 sm:gap-x-4 sm:px-4 grid-cols-[minmax(0,1fr)_6.5rem_2.75rem] md:grid-cols-[minmax(0,1.3fr)_minmax(0,1fr)_9rem_4.5rem_7.5rem_5.75rem_1.25rem] lg:grid-cols-[minmax(0,1.3fr)_minmax(0,1fr)_9rem_4.5rem_5.5rem_7.5rem_5.75rem_1.25rem]"

  defp grid_class, do: @grid

  @doc false
  # Precio para pegar en la ventana de orden del cliente: sin separadores de miles.
  @spec price_text(float()) :: String.t()
  def price_text(price), do: :erlang.float_to_binary(price, decimals: 2)

  defp pct(x), do: "#{:erlang.float_to_binary(x * 100, decimals: 1)} %"
  defp pct2(x), do: "#{:erlang.float_to_binary(x * 100, decimals: 2)} %"

  defp short_name(name), do: name |> String.split(" - ") |> hd()
end
