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

  - Diseño F10 (§9.5): cabecera del tablón, sellos, anillo de Certeza, ficha con "?" al
    manual y anillo de órdenes usadas frente al límite.

  Implementa: RF-4.16, RF-4.17, RF-6.4, RF-6.12, RF-6.13, RF-11.2.
  """
  use EthWeb, :live_view

  import EthWeb.TradingComponents

  alias Eth.{Characters, Clock, Engine, GameRules, Market, Sde}
  alias Eth.Characters.Pilot
  alias Eth.Engine.{OwnOrders, StationQuery}
  alias EthWeb.{Format, StationParams}

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

  def handle_event("select", %{"id" => id}, socket) do
    selected = if socket.assigns.selected == id, do: nil, else: id

    {:noreply,
     socket
     |> assign(:selected, selected)
     |> assign(:selected_row, selected_row(selected, socket.assigns.query))}
  end

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
  def handle_info({:opportunities_updated, _meta}, socket), do: {:noreply, load_rows(socket)}
  def handle_info({:history_updated, _count}, socket), do: {:noreply, load_rows(socket)}

  # `EthWeb.PilotHook` ya actualizó @pilot; solo se recalcula si cambió lo que usa la consulta.
  def handle_info({:character, _id, _event, _public}, socket) do
    new = overrides(socket.assigns.pilot)
    socket = assign_my_orders(socket)

    if new == socket.assigns.pilot_overrides,
      do: {:noreply, socket},
      else: {:noreply, socket |> assign(:pilot_overrides, new) |> apply_filters() |> load_rows()}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp overrides(nil), do: %{}
  defp overrides(pilot), do: Pilot.station_overrides(pilot)

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

    socket
    |> assign(:form_defaults, defaults)
    |> assign(:form, to_form(form, as: :filters))
    |> assign(:query, query)
  end

  defp load_rows(socket) do
    {rows, total} = Engine.station_query(socket.assigns.query)

    socket
    |> assign_my_orders()
    |> assign(total: total, meta: Engine.meta(), now: Clock.utc_now())
    |> assign(:reward, Enum.reduce(rows, 0.0, &(&1.profit_day + &2)))
    |> assign(:selected_row, selected_row(socket.assigns.selected, socket.assigns.query))
    |> stream(:rows, rows, reset: true)
  end

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

  defp hubs do
    for id <- GameRules.get(:station_trading_location_ids),
        station = Sde.station(id),
        station != nil,
        do: {station.name, Integer.to_string(id)}
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

  @doc false
  # Precio para pegar en la ventana de orden del cliente: sin separadores de miles.
  @spec price_text(float()) :: String.t()
  def price_text(price), do: :erlang.float_to_binary(price, decimals: 2)

  defp pct(x), do: "#{:erlang.float_to_binary(x * 100, decimals: 1)} %"
  defp pct2(x), do: "#{:erlang.float_to_binary(x * 100, decimals: 2)} %"

  defp short_name(name), do: name |> String.split(" - ") |> hd()
end
