defmodule EthWeb.RadarHook do
  @moduledoc """
  Estado del radar para la cabecera de todas las vistas (RF-3.8): asigna
  `@radar_degraded` y lo mantiene al día con `threat:heatmap`. El mensaje sigue su curso
  (`:cont`), así cada LiveView puede reaccionar además a los cambios del mapa de calor.

  Implementa: RF-3.8.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView

  alias Eth.Threat

  @spec on_mount(:default, map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()}
  def on_mount(:default, _params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Eth.PubSub, Threat.heat_topic())

    socket =
      socket
      |> assign(:radar_degraded, Threat.degraded?())
      |> attach_hook(:radar_status, :handle_info, &handle_info/2)

    {:cont, socket}
  end

  defp handle_info({:heatmap, _version}, socket),
    do: {:cont, assign(socket, :radar_degraded, Threat.degraded?())}

  defp handle_info(_msg, socket), do: {:cont, socket}
end
