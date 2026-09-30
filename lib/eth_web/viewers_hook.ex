defmodule EthWeb.ViewersHook do
  @moduledoc """
  Cuenta las pantallas conectadas para el pipeline del Centro de control (RF-8.4): cada
  LiveView conectada se registra en `Eth.Metrics`, que la descuenta al terminar.

  Implementa: RF-8.4.
  """

  import Phoenix.LiveView

  @spec on_mount(:default, map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()}
  def on_mount(:default, _params, _session, socket) do
    if connected?(socket), do: Eth.Metrics.viewer_joined(self())
    {:cont, socket}
  end
end
