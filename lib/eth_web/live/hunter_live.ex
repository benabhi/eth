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

  Modo invitado (F3): impuestos, capital y bodega manuales; el login con EVE SSO llega en F4.

  Implementa: RF-6.2, RF-6.3, RF-6.4, RF-6.5, RF-6.6, RF-6.10.
  """
  use EthWeb, :live_view

  alias Eth.{Clock, Engine, Sde}
  alias Eth.Engine.Query
  alias EthWeb.{Format, HunterParams}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Eth.PubSub, Engine.topic())

    socket =
      socket
      |> assign(:page_title, gettext("Cazador de trades"))
      |> assign(:frozen, false)
      |> assign(:pending, 0)
      |> assign(:selected, nil)
      |> assign(:total, 0)
      |> assign(:meta, Engine.meta())
      |> assign(:now, Clock.utc_now())
      |> stream_configure(:rows, dom_id: &"opp-#{&1.id}")
      |> stream(:rows, [])

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    form = Map.merge(HunterParams.form_defaults(), Map.take(params, HunterParams.fields()))

    {:noreply,
     socket
     |> assign(:form, to_form(form, as: :filters))
     |> assign(:query, HunterParams.to_query(form))
     |> load_rows()}
  end

  @impl true
  def handle_event("filter", %{"filters" => filters}, socket) do
    {:noreply, push_patch(socket, to: ~p"/?#{HunterParams.to_url_params(filters)}")}
  end

  def handle_event("reset_filters", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/")}
  end

  def handle_event("select", %{"id" => id}, socket) do
    selected = if socket.assigns.selected == id, do: nil, else: id

    {:noreply,
     socket
     |> assign(:selected, selected)
     |> assign(:selected_row, selected_row(selected, socket.assigns.query))}
  end

  def handle_event("toggle_freeze", _params, socket) do
    if socket.assigns.frozen do
      {:noreply, socket |> assign(frozen: false, pending: 0) |> load_rows()}
    else
      {:noreply, assign(socket, :frozen, true)}
    end
  end

  def handle_event("copied", _params, socket) do
    {:noreply, put_flash(socket, :info, gettext("Multibuy copiado al portapapeles"))}
  end

  @impl true
  def handle_info({:opportunities_updated, _meta}, %{assigns: %{frozen: true}} = socket) do
    {:noreply, update(socket, :pending, &(&1 + 1))}
  end

  def handle_info({:opportunities_updated, _meta}, socket), do: {:noreply, load_rows(socket)}
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp load_rows(socket) do
    {rows, total} = Engine.query(socket.assigns.query)

    socket
    |> assign(total: total, meta: Engine.meta(), now: Clock.utc_now(), empty?: rows == [])
    |> assign(:selected_row, selected_row(socket.assigns[:selected], socket.assigns.query))
    |> stream(:rows, rows, reset: true)
  end

  # La fila seleccionada se recalcula aparte: puede no estar entre las 200 visibles.
  defp selected_row(nil, _query), do: nil

  defp selected_row(id, query) do
    case Engine.get(id) do
      nil -> nil
      opp -> Query.personalize(opp, Map.merge(Query.defaults(), query), Clock.utc_now())
    end
  end

  ## Presentación

  @doc false
  # Línea Multibuy por objeto: `Nombre<TAB>Cantidad` (RF-6.6). El TAB evita la ambigüedad
  # con nombres que terminan en número ("Navy Cap Booster 400").
  @spec multibuy(map()) :: String.t()
  def multibuy(row), do: "#{row.opportunity.type_name}\t#{row.quantity}"

  defp sec_style(nil), do: ""
  defp sec_style(sec), do: "color: #{Sde.security_color(sec)}"

  defp sec_label(nil), do: "?"
  defp sec_label(sec), do: :erlang.float_to_binary(Sde.security_display(sec), decimals: 1)

  defp pct(x), do: "#{:erlang.float_to_binary(x * 100, decimals: 1)} %"

  defp tvs_class(tvs) when tvs >= 75, do: "badge-success"
  defp tvs_class(tvs) when tvs >= 40, do: "badge-warning"
  defp tvs_class(_tvs), do: "badge-ghost"

  defp route_label(:secure), do: gettext("Segura")
  defp route_label(_shortest), do: gettext("Rápida")
end
