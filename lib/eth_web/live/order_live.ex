defmodule EthWeb.OrderLive do
  @moduledoc """
  Trading por órdenes entre estaciones (RF-4.1, RF-6.12): la familia **Por órdenes** del
  Cazador, con sus dos modos:

  - **Listado:** comprar barato en el origen y publicar una orden de venta en un hub.
  - **Compra por orden:** publicar una orden de compra en un hub y vender a órdenes de
    compra del destino cuando se llene.

  Filtros en la URL (RF-6.4); con un piloto activo, Accounting, Broker Relations,
  standings, capital, bodega, sistema de partida y sus órdenes (que no compiten con él)
  salen de su contexto. La grilla muestra el precio sugerido, la cantidad, el beneficio,
  el tiempo estimado de ejecución y la Certeza; el detalle explica cada tramo con sus
  comisiones. ESI no permite publicar órdenes (D-12): el precio se copia y la orden se
  publica en el cliente.

  Diseño F10 (§9.5): cabecera del tablón, filtros acoplados a la tabla, sellos, anillo de
  Certeza y ficha que se despliega bajo la fila (RF-6.5), con pasos numerados y "?" al
  manual.

  Implementa: RF-4.1, RF-6.4, RF-6.12, RF-6.13, RF-11.2.
  """
  use EthWeb, :live_view

  import EthWeb.TradingComponents

  alias Eth.{Characters, Clock, Engine, Market, Sde}
  alias Eth.Characters.Pilot
  alias Eth.Engine.OrderQuery
  alias EthWeb.{Format, OrderParams}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Eth.PubSub, Engine.topic())
      Phoenix.PubSub.subscribe(Eth.PubSub, Market.history_topic())
    end

    {:ok,
     socket
     |> assign(:page_title, gettext("Trading por órdenes"))
     |> assign(:selected, nil)
     |> assign(:selected_row, nil)
     |> assign(:total, 0)
     |> assign(:pending, 0)
     |> assign(:reward, 0.0)
     |> assign(:url_params, %{})
     |> assign(:pilot_overrides, overrides(socket.assigns.pilot))
     |> stream_configure(:rows, dom_id: &"ord-#{&1.id}")
     |> stream(:rows, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:url_params, Map.take(params, OrderParams.fields()))
     |> apply_filters()
     |> load_rows()}
  end

  @impl true
  def handle_event("filter", %{"filters" => filters}, socket) do
    url_params = OrderParams.to_url_params(filters, socket.assigns.form_defaults)
    {:noreply, push_patch(socket, to: ~p"/orders?#{url_params}")}
  end

  def handle_event("reset_filters", _params, socket),
    do: {:noreply, push_patch(socket, to: ~p"/orders")}

  # Clic en una fila: abre su ficha debajo, o la cierra si ya estaba abierta (RF-6.5).
  def handle_event("select", %{"id" => id}, socket) do
    if socket.assigns.selected == id,
      do: {:noreply, close_detail(socket)},
      else: {:noreply, open_detail(socket, id)}
  end

  def handle_event("close_detail", _params, socket), do: {:noreply, close_detail(socket)}

  def handle_event("copied", _params, socket),
    do: {:noreply, put_flash(socket, :info, gettext("Copiado al portapapeles"))}

  def handle_event("open_market", _params, socket) do
    with %{} = row <- socket.assigns.selected_row,
         %{} = pilot <- socket.assigns.pilot,
         true <- Pilot.scope?(pilot, "esi-ui.open_window.v1") and pilot.status == :ok do
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

  def handle_info({:character, _id, _event, _public}, socket) do
    new = overrides(socket.assigns.pilot)

    if new == socket.assigns.pilot_overrides,
      do: {:noreply, socket},
      else: {:noreply, socket |> assign(:pilot_overrides, new) |> apply_filters() |> load_rows()}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # Parámetros del piloto: los del Cazador (capital, bodega, origen, nave) y los de las
  # órdenes (Broker Relations, standings y sus órdenes).
  defp overrides(nil), do: %{}

  defp overrides(pilot),
    do: Map.merge(Pilot.query_overrides(pilot), Pilot.station_overrides(pilot))

  ## Ficha bajo la fila (RF-6.5)

  # Con una ficha abierta la grilla se congela: los cambios quedan pendientes (RF-6.3).
  defp refresh(%{assigns: %{selected: nil}} = socket), do: load_rows(socket)
  defp refresh(socket), do: update(socket, :pending, &(&1 + 1))

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

    if socket.assigns.pending > 0,
      do: socket |> assign(:pending, 0) |> load_rows(),
      else: socket
  end

  defp reinsert(socket, nil), do: socket
  defp reinsert(socket, row), do: stream_insert(socket, :rows, row)

  defp apply_filters(socket) do
    overrides = socket.assigns.pilot_overrides
    defaults = OrderParams.form_defaults(overrides)
    form = Map.merge(defaults, socket.assigns.url_params)

    query =
      form
      |> OrderParams.to_query()
      |> Map.merge(
        Map.take(overrides, [:standings, :own_order_ids, :base_system_id, :ship_class])
      )

    socket
    |> assign(:form_defaults, defaults)
    |> assign(:form, to_form(form, as: :filters))
    |> assign(:query, query)
  end

  defp load_rows(socket) do
    {rows, total} = Engine.order_query(socket.assigns.query)

    socket
    |> assign(total: total, meta: Engine.meta(), now: Clock.utc_now())
    |> assign(:reward, Enum.reduce(rows, 0.0, &(&1.profit + &2)))
    |> assign(:selected_row, selected_row(socket.assigns.selected, socket.assigns.query))
    |> stream(:rows, rows, reset: true)
  end

  defp selected_row(nil, _query), do: nil

  defp selected_row(id, query) do
    case Engine.order_get(id) do
      nil -> nil
      opp -> OrderQuery.personalize(opp, query, Clock.utc_now())
    end
  end

  ## Presentación

  # Columnas de la grilla, iguales en el encabezado y en cada fila (RNF-5.9).
  @grid "grid items-center gap-x-4 px-4 grid-cols-[minmax(0,1fr)_6.5rem_4.5rem_2.75rem] md:grid-cols-[minmax(0,1.2fr)_minmax(0,1.5fr)_6rem_7rem_4.5rem_4.5rem_1.25rem] lg:grid-cols-[minmax(0,1.2fr)_minmax(0,1.5fr)_6rem_7rem_4.5rem_3.5rem_4.5rem_1.25rem]"

  defp grid_class, do: @grid

  @doc false
  # Precio para pegar en la ventana de orden del cliente: sin separadores de miles.
  @spec price_text(float()) :: String.t()
  def price_text(price), do: :erlang.float_to_binary(price, decimals: 2)

  defp mode_label(:listing), do: gettext("Listado")
  defp mode_label(:buy_order), do: gettext("Compra por orden")

  # Pasos del modo, en orden, para la ficha.
  defp how_to(%{mode: :listing} = r) do
    [
      gettext("Comprá %{qty} unidades en el origen (a sus órdenes de venta).",
        qty: Format.integer(r.quantity)
      ),
      gettext("Llevalas al hub (%{jumps} saltos).", jumps: r.jumps),
      gettext("Publicá una orden de venta al precio sugerido y esperá a que se venda.")
    ]
  end

  defp how_to(r) do
    [
      gettext("Publicá en el hub una orden de compra por %{qty} unidades al precio sugerido.",
        qty: Format.integer(r.quantity)
      ),
      gettext("Cuando se llene, llevá la carga al destino (%{jumps} saltos).", jumps: r.jumps),
      gettext("Vendé a las órdenes de compra del destino.")
    ]
  end

  defp price_label(:listing), do: gettext("Orden de venta en el hub")
  defp price_label(:buy_order), do: gettext("Orden de compra en el hub")

  defp pct(x), do: "#{:erlang.float_to_binary(x * 100, decimals: 1)} %"
  defp pct2(x), do: "#{:erlang.float_to_binary(x * 100, decimals: 2)} %"

  defp days_label(days) when days < 1, do: gettext("< 1 día")

  defp days_label(days),
    do: gettext("%{days} días", days: :erlang.float_to_binary(days, decimals: 1))

  defp sec_style(nil), do: ""
  defp sec_style(sec), do: "color: #{Sde.security_color(sec)}"

  defp sec_label(nil), do: "?"
  defp sec_label(sec), do: :erlang.float_to_binary(Sde.security_display(sec), decimals: 1)
end
