defmodule EthWeb.RunLive do
  @moduledoc """
  Viaje activo (ERS §9.5): el contrato que el piloto está cazando.

  - Etapas del viaje (RF-7.2) con el momento de cada una y la ubicación en vivo.
  - Revalidación (RF-7.3): beneficio proyectado actual, alertas y mejor destino sugerido.
  - Amenazas en la ruta restante (RF-7.4) con la ruta evasiva aplicable con un clic.
  - Acciones: fijar la ruta, abrir el mercado del tipo en el juego, confirmar compra o
    venta a mano y abortar.
  - Historial de viajes (RF-7.6): proyectado frente a real, desvío e ISK/h real.
  - Registro del cazador (RF-7.7): rango con su progreso, estadísticas por período
    (semana, mes, histórico) del piloto o de todos sus personajes, e hitos con el
    momento y el viaje en que se lograron.

  Se actualiza con `run:<personaje>` y un tick que refresca el estado en vivo del monitor.

  Implementa: RF-7.1, RF-7.2, RF-7.3, RF-7.4, RF-7.5, RF-7.6, RF-7.7.
  """
  use EthWeb, :live_view

  alias Eth.{Characters, Tracking}
  alias Eth.Characters.Pilot
  alias Eth.Tracking.RunMonitor
  alias EthWeb.Format

  @tick_ms 5_000
  @steps ~w(planned to_origin bought in_transit at_destination closed)

  @impl true
  def mount(_params, _session, socket) do
    pilot = socket.assigns.pilot

    if connected?(socket) && pilot do
      Phoenix.PubSub.subscribe(Eth.PubSub, Tracking.topic(pilot.id))
      Process.send_after(self(), :tick, @tick_ms)
    end

    {:ok,
     socket
     |> assign(:page_title, gettext("Viaje activo"))
     |> assign(:steps, @steps)
     |> assign(:alerts, [])
     |> assign(log_period: "all", log_scope: "me")
     |> load()}
  end

  defp load(%{assigns: %{pilot: nil}} = socket),
    do: assign(socket, run: nil, live: nil, history: [], log: nil)

  defp load(socket) do
    id = socket.assigns.pilot.id
    run = Tracking.active(id)

    socket
    |> assign(:run, run)
    |> assign(:live, run && RunMonitor.live(run.id))
    |> assign(:history, Tracking.history(id))
    |> assign(:log, Tracking.hunter_log(log_characters(socket)))
  end

  # Registro del piloto activo o de todos los personajes del operador (RF-7.7).
  defp log_characters(%{assigns: %{log_scope: "all", characters: characters}})
       when characters != [],
       do: Enum.map(characters, & &1.id)

  defp log_characters(socket), do: socket.assigns.pilot.id

  @impl true
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, @tick_ms)
    {:noreply, load(socket)}
  end

  def handle_info({:run, _run, {:alert, message}}, socket) do
    {:noreply,
     socket
     |> update(:alerts, &Enum.take([{DateTime.utc_now(), message} | &1], 10))
     |> put_flash(:error, message)
     |> load()}
  end

  def handle_info({:run, _run, _extra}, socket), do: {:noreply, load(socket)}
  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("confirm", %{"action" => action}, socket) do
    action = if action == "sold", do: :sold, else: :bought

    case socket.assigns.run && Tracking.confirm(socket.assigns.run, action) do
      {:ok, _run} ->
        {:noreply, load(socket)}

      _ ->
        {:noreply,
         put_flash(socket, :error, gettext("Esa confirmación no corresponde a la etapa actual"))}
    end
  end

  def handle_event("log_period", %{"period" => period}, socket)
      when period in ~w(week month all),
      do: {:noreply, assign(socket, :log_period, period)}

  def handle_event("log_scope", %{"scope" => scope}, socket) when scope in ~w(me all),
    do: {:noreply, socket |> assign(:log_scope, scope) |> load()}

  def handle_event("abort", _params, socket) do
    if run = socket.assigns.run, do: Tracking.abort(run)
    {:noreply, socket |> put_flash(:info, gettext("Viaje abortado")) |> load()}
  end

  def handle_event("set_route", _params, socket) do
    with %{} = run <- socket.assigns.run,
         %{} = pilot <- socket.assigns.pilot do
      at_origin? = Pilot.at_location?(pilot, run.plan["origin_location_id"])
      bought? = run.status not in ["planned", "to_origin"]

      result =
        Characters.set_route(
          pilot.id,
          run.plan["origin_location_id"],
          run.plan["destination_location_id"],
          at_origin? or bought?
        )

      {:noreply, route_flash(socket, result, gettext("Ruta del viaje fijada en el juego"))}
    else
      _ -> {:noreply, socket}
    end
  end

  # Abre en el cliente la ventana de mercado del tipo del viaje (RF-5.9), como en el
  # tablón. Va en segundo plano: la llamada a ESI no bloquea la vista.
  def handle_event("open_market", _params, socket) do
    with %{} = run <- socket.assigns.run,
         type_id when is_integer(type_id) <- run.plan["type_id"],
         %{} = pilot <- socket.assigns.pilot,
         nil <- market_blocked(pilot) do
      {:noreply,
       start_async(socket, :open_market, fn -> Characters.open_market(pilot.id, type_id) end)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("apply_evasive", _params, socket) do
    result = socket.assigns.run && RunMonitor.apply_evasive(socket.assigns.run.id)
    {:noreply, route_flash(socket, result, gettext("Ruta evasiva fijada en el juego"))}
  end

  @impl true
  def handle_async(:open_market, {:ok, :ok}, socket),
    do: {:noreply, put_flash(socket, :info, gettext("Mercado abierto en el juego"))}

  def handle_async(:open_market, {:ok, {:error, reason}}, socket),
    do: {:noreply, put_flash(socket, :error, market_error(reason))}

  def handle_async(:open_market, {:exit, _reason}, socket),
    do: {:noreply, put_flash(socket, :error, gettext("La acción in-game falló"))}

  # Motivo por el que no se puede abrir el mercado en el juego (`nil` si se puede).
  defp market_blocked(nil), do: gettext("Iniciá sesión con EVE para usar las acciones in-game")

  defp market_blocked(pilot) do
    cond do
      not Pilot.scope?(pilot, "esi-ui.open_window.v1") ->
        gettext("Falta el permiso %{scope}: volvé a iniciar sesión",
          scope: "esi-ui.open_window.v1"
        )

      pilot.status != :ok ->
        gettext("La sesión de EVE del personaje no está lista")

      pilot.online == false ->
        gettext("El personaje no está conectado al juego")

      true ->
        nil
    end
  end

  defp market_error(:relogin),
    do: gettext("La autorización de EVE venció: volvé a iniciar sesión")

  defp market_error({:http, %{status: 403}}),
    do: gettext("EVE rechazó la acción: falta el permiso o el personaje no está conectado")

  defp market_error({:http, %{status: status}}),
    do: gettext("EVE rechazó la acción (HTTP %{status})", status: status)

  defp market_error({reason, _until}) when reason in [:paused, :rate_limited],
    do: gettext("ESI está en pausa: probá de nuevo en unos segundos")

  defp market_error(_reason), do: gettext("La sesión de EVE del personaje no está lista")

  defp route_flash(socket, :ok, message), do: put_flash(socket, :info, message)

  defp route_flash(socket, _error, _message),
    do: put_flash(socket, :error, gettext("No se pudo fijar la ruta: revisá la sesión de EVE"))

  ## Presentación

  defp step_state(run, step) do
    current = Enum.find_index(@steps, &(&1 == run.status)) || 0
    index = Enum.find_index(@steps, &(&1 == step))

    cond do
      index < current -> :done
      index == current -> :current
      true -> :pending
    end
  end

  defp step_time(run, step) do
    case run.stages[step] do
      nil -> nil
      iso -> iso |> DateTime.from_iso8601() |> elem(1) |> Calendar.strftime("%H:%M")
    end
  end

  defp label(status), do: Tracking.status_label(status)

  defp period_stats(log, "week"), do: log.week
  defp period_stats(log, "month"), do: log.month
  defp period_stats(log, _all), do: log.all

  defp status_seal("closed"), do: :improved
  defp status_seal("aborted"), do: :expired
  defp status_seal(_active), do: :new

  defp deviation(%{result: %{"deviation" => d}}) when is_number(d),
    do: "#{if d >= 0, do: "+", else: ""}#{round(d * 100)} %"

  defp deviation(_run), do: "—"

  defp real_isk_per_hour(%{realized_profit: profit, started_at: s, closed_at: c})
       when is_number(profit) and not is_nil(c) do
    hours = max(DateTime.diff(c, s), 60) / 3600
    Format.compact(profit / hours)
  end

  defp real_isk_per_hour(_run), do: "—"

  defp location_label(nil), do: gettext("sin datos de ubicación")

  defp location_label(location) do
    system = (Eth.Sde.system(location[:solar_system_id]) || %{name: "?"}).name

    if location[:station_id] || location[:structure_id],
      do: gettext("atracado en %{system}", system: system),
      else: gettext("en el espacio · %{system}", system: system)
  end
end
