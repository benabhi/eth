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

  Implementa: RF-4.7, RF-4.8, RF-5.9, RF-6.2, RF-6.3, RF-6.4, RF-6.5, RF-6.6, RF-6.7,
  RF-6.10.
  """
  use EthWeb, :live_view

  alias Eth.{Characters, Clock, Engine, Market, Sde}
  alias Eth.Characters.Pilot
  alias Eth.Engine.Query
  alias EthWeb.{Format, HunterParams}

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
      |> assign(:total, 0)
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
  def handle_info({:opportunities_updated, _meta}, %{assigns: %{frozen: true}} = socket) do
    {:noreply, update(socket, :pending, &(&1 + 1))}
  end

  def handle_info({:opportunities_updated, _meta}, socket), do: {:noreply, load_rows(socket)}

  # Estadísticas de historial nuevas (RF-1.12): cambian anti-scam, liquidez y TVS.
  def handle_info({:history_updated, _count}, %{assigns: %{frozen: true}} = socket) do
    {:noreply, update(socket, :pending, &(&1 + 1))}
  end

  def handle_info({:history_updated, _count}, socket), do: {:noreply, load_rows(socket)}

  # `EthWeb.PilotHook` ya actualizó @pilot; solo se recalcula si cambió lo que usa el motor.
  def handle_info({:character, _id, _event, _public}, socket) do
    overrides = pilot_overrides(socket.assigns.pilot)

    cond do
      overrides == socket.assigns.pilot_overrides ->
        {:noreply, socket}

      socket.assigns.frozen ->
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

  def handle_info(_msg, socket), do: {:noreply, socket}

  # Defaults del formulario = modo invitado + datos del piloto; la URL tiene prioridad.
  defp apply_filters(socket) do
    overrides = socket.assigns.pilot_overrides
    defaults = HunterParams.form_defaults(overrides)
    form = Map.merge(defaults, socket.assigns.url_params)

    query =
      form
      |> HunterParams.to_query()
      |> Map.merge(Map.take(overrides, [:base_system_id, :ship_class]))

    socket
    |> assign(:form_defaults, defaults)
    |> assign(:form, to_form(form, as: :filters))
    |> assign(:query, query)
  end

  defp pilot_overrides(nil), do: %{}
  defp pilot_overrides(pilot), do: Pilot.query_overrides(pilot)

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

  defp shield_label(:scam), do: gettext("☠ SCAM")
  defp shield_label(:suspicious), do: gettext("⚠ sospechosa")
  defp shield_label(:no_history), do: gettext("sin historial")
  defp shield_label(:ok), do: gettext("ok")

  defp shield_class(:scam), do: "badge-error"
  defp shield_class(:suspicious), do: "badge-warning"
  defp shield_class(_status), do: "badge-ghost"

  @doc false
  # Puntos de un sparkline SVG (viewBox 0 0 120 32) con los promedios diarios; los días
  # sin operaciones cortan la línea. Devuelve una lista de tramos `"x,y x,y …"`.
  @spec sparkline([float() | nil]) :: [String.t()]
  def sparkline(values) do
    present = Enum.reject(values, &is_nil/1)

    if present == [] do
      []
    else
      {low, high} = Enum.min_max(present)
      span = if high - low > 0, do: high - low, else: 1.0
      step = 120 / max(length(values) - 1, 1)

      values
      |> Enum.with_index()
      |> Enum.chunk_by(fn {value, _i} -> is_nil(value) end)
      |> Enum.reject(fn [{value, _i} | _] -> is_nil(value) end)
      |> Enum.map(fn chunk ->
        Enum.map_join(chunk, " ", fn {value, i} ->
          x = Float.round(i * step, 1)
          y = Float.round(30 - (value - low) / span * 28, 1)
          "#{x},#{y}"
        end)
      end)
    end
  end

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
