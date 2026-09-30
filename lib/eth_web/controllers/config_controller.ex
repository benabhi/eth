defmodule EthWeb.ConfigController do
  @moduledoc """
  Descarga de la configuración del operador como JSON (RF-9.7). El archivo no lleva
  secretos ni tokens: lo arma `Eth.ConfigTransfer.export/0`.

  Implementa: RF-9.7.
  """
  use EthWeb, :controller

  alias Eth.ConfigTransfer

  @doc "Descarga `eth-config-<fecha>.json`."
  @spec export(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def export(conn, _params) do
    json = Jason.encode!(ConfigTransfer.export(), pretty: true)

    send_download(conn, {:binary, json},
      filename: ConfigTransfer.filename(),
      content_type: "application/json"
    )
  end
end
