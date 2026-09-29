defmodule EthWeb.RunLive do
  @moduledoc """
  Viaje activo (ERS §9.5): el contrato que el piloto está cazando.

  - Etapas del viaje (RF-7.2) con el momento de cada una y la ubicación en vivo.
  - Revalidación (RF-7.3): beneficio proyectado actual, alertas y mejor destino sugerido.
  - Amenazas en la ruta restante (RF-7.4) con la ruta evasiva aplicable con un clic.
  - Acciones: fijar la ruta, confirmar compra o venta a mano y abortar.
  - Historial de viajes (RF-7.6): proyectado frente a real, desvío e ISK/h real.

  Se actualiza con `run:<personaje>` y un tick que refresca el estado en vivo del monitor.

  Implementa: RF-7.1, RF-7.2, RF-7.3, RF-7.4, RF-7.5, RF-7.6.
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
     |> load()}
  end

  defp load(%{assigns: %{pilot: nil}} = socket),
    do: assign(socket, run: nil, live: nil, history: [])

  defp load(socket) do
    id = socket.assigns.pilot.id
    run = Tracking.active(id)

    socket
    |> assign(:run, run)
    |> assign(:live, run && RunMonitor.live(run.id))
    |> assign(:history, Tracking.history(id))
  end

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

  def handle_event("apply_evasive", _params, socket) do
    result = socket.assigns.run && RunMonitor.apply_evasive(socket.assigns.run.id)
    {:noreply, route_flash(socket, result, gettext("Ruta evasiva fijada en el juego"))}
  end

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
