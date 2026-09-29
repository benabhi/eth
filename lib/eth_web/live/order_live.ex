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

  Implementa: RF-4.1, RF-6.4, RF-6.12.
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

  def handle_event("select", %{"id" => id}, socket) do
    selected = if socket.assigns.selected == id, do: nil, else: id

    {:noreply,
     socket
     |> assign(:selected, selected)
     |> assign(:selected_row, selected_row(selected, socket.assigns.query))}
  end

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
  def handle_info({:opportunities_updated, _meta}, socket), do: {:noreply, load_rows(socket)}
  def handle_info({:history_updated, _count}, socket), do: {:noreply, load_rows(socket)}

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

  @doc false
  # Precio para pegar en la ventana de orden del cliente: sin separadores de miles.
  @spec price_text(float()) :: String.t()
  def price_text(price), do: :erlang.float_to_binary(price, decimals: 2)

  defp mode_label(:listing), do: gettext("Listado")
  defp mode_label(:buy_order), do: gettext("Compra por orden")

  defp price_label(:listing), do: gettext("Orden de venta en el hub")
  defp price_label(:buy_order), do: gettext("Orden de compra en el hub")

  defp pct(x), do: "#{:erlang.float_to_binary(x * 100, decimals: 1)} %"
  defp pct2(x), do: "#{:erlang.float_to_binary(x * 100, decimals: 2)} %"

  defp days_label(days) when days < 1, do: gettext("< 1 día")

  defp days_label(days),
    do: gettext("%{days} días", days: :erlang.float_to_binary(days, decimals: 1))

  defp shield_label(:scam), do: gettext("☠ SCAM")
  defp shield_label(:suspicious), do: gettext("⚠ sospechosa")
  defp shield_label(:no_history), do: gettext("sin historial")

  defp shield_class(:scam), do: "badge-error"
  defp shield_class(:suspicious), do: "badge-warning"
  defp shield_class(_status), do: "badge-ghost"

  defp certainty_class(c) when c >= 0.7, do: "badge-success"
  defp certainty_class(c) when c >= 0.4, do: "badge-warning"
  defp certainty_class(_c), do: "badge-ghost"

  defp sec_style(nil), do: ""
  defp sec_style(sec), do: "color: #{Sde.security_color(sec)}"

  defp sec_label(nil), do: "?"
  defp sec_label(sec), do: :erlang.float_to_binary(Sde.security_display(sec), decimals: 1)
end
