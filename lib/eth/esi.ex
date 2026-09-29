defmodule Eth.Esi do
  @moduledoc """
  Rutas de ESI usadas por la aplicación (ERS §6.1). Es el único lugar que conoce las
  URLs; el transporte, la caché y el presupuesto los resuelve `Eth.Esi.Client`.

  Implementa: RF-1.1.
  """

  alias Eth.Esi.{Client, Response}

  @market_group "market-order"

  @doc "Estado de Tranquility (`/status`)."
  @spec status() :: {:ok, Response.t()} | {:error, Client.error()}
  def status, do: Client.get("/status", group: "status")

  @doc "IDs de todas las regiones (`/universe/regions`)."
  @spec region_ids() :: {:ok, Response.t()} | {:error, Client.error()}
  def region_ids, do: Client.get("/universe/regions")

  @doc "Resuelve nombres de IDs (`POST /universe/names`, máx. 1000 IDs)."
  @spec names([pos_integer()]) :: {:ok, Response.t()} | {:error, Client.error()}
  def names(ids) when is_list(ids) and length(ids) <= 1000,
    do: Client.post("/universe/names", ids)

  @doc """
  Una página de órdenes de mercado de una región (`/markets/{region_id}/orders`).
  Con `etag` envía `If-None-Match` (un 304 cuesta 1 token en lugar de 2).
  """
  @spec market_orders(pos_integer(), pos_integer(), String.t() | nil) ::
          {:ok, Response.t()} | {:error, Client.error()}
  def market_orders(region_id, page, etag \\ nil) do
    Client.get("/markets/#{region_id}/orders",
      params: [order_type: "all", page: page],
      etag: etag,
      group: @market_group
    )
  end
end
