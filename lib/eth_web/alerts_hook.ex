defmodule EthWeb.AlertsHook do
  @moduledoc """
  Alertas en todas las vistas (RF-10.1, RF-10.2): se suscribe a `notifications`, muestra
  cada alerta como toast y la reenvía al navegador (`eth:notify`), donde el hook
  `.Notifier` del layout la convierte en notificación nativa y sonido si el usuario los
  activó. El mensaje no llega a la LiveView (`:halt`).

  Implementa: RF-10.1, RF-10.2.
  """

  import Phoenix.LiveView

  alias Eth.Notifications

  @spec on_mount(:default, map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()}
  def on_mount(:default, _params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Eth.PubSub, Notifications.topic())
    {:cont, attach_hook(socket, :alerts, :handle_info, &handle_info/2)}
  end

  defp handle_info({:alert, alert}, socket) do
    kind = if alert.level == :info, do: :info, else: :error
    text = if alert.body in [nil, ""], do: alert.title, else: "#{alert.title} · #{alert.body}"

    socket =
      socket
      |> put_flash(kind, text)
      |> push_event("eth:notify", %{title: alert.title, body: alert.body, url: alert.url})

    {:halt, socket}
  end

  defp handle_info(_msg, socket), do: {:cont, socket}
end
