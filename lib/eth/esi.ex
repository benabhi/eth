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

  ## Rutas autenticadas del personaje (RF-5.4 a RF-5.9)

  @doc "Ubicación actual (`esi-location.read_location.v1`)."
  @spec character_location(pos_integer(), String.t(), String.t() | nil) ::
          {:ok, Response.t()} | {:error, Client.error()}
  def character_location(id, token, etag \\ nil),
    do: character_get(id, "location", token, etag, "char-location")

  @doc "Nave activa (`esi-location.read_ship_type.v1`)."
  @spec character_ship(pos_integer(), String.t(), String.t() | nil) ::
          {:ok, Response.t()} | {:error, Client.error()}
  def character_ship(id, token, etag \\ nil),
    do: character_get(id, "ship", token, etag, "char-location")

  @doc "Estado en línea (`esi-location.read_online.v1`)."
  @spec character_online(pos_integer(), String.t(), String.t() | nil) ::
          {:ok, Response.t()} | {:error, Client.error()}
  def character_online(id, token, etag \\ nil),
    do: character_get(id, "online", token, etag, "char-location")

  @doc "Saldo de la billetera (`esi-wallet.read_character_wallet.v1`)."
  @spec character_wallet(pos_integer(), String.t(), String.t() | nil) ::
          {:ok, Response.t()} | {:error, Client.error()}
  def character_wallet(id, token, etag \\ nil),
    do: character_get(id, "wallet", token, etag, "char-wallet")

  @doc "Habilidades (`esi-skills.read_skills.v1`)."
  @spec character_skills(pos_integer(), String.t(), String.t() | nil) ::
          {:ok, Response.t()} | {:error, Client.error()}
  def character_skills(id, token, etag \\ nil),
    do: character_get(id, "skills", token, etag, "char-detail")

  @doc "Standings con NPCs (`esi-characters.read_standings.v1`)."
  @spec character_standings(pos_integer(), String.t(), String.t() | nil) ::
          {:ok, Response.t()} | {:error, Client.error()}
  def character_standings(id, token, etag \\ nil),
    do: character_get(id, "standings", token, etag, "char-social")

  defp character_get(id, resource, token, etag, group) do
    Client.get("/characters/#{id}/#{resource}",
      token: token,
      etag: etag,
      character_id: id,
      group: group
    )
  end

  @doc """
  Agrega un waypoint en el autopiloto del cliente (`esi-ui.write_waypoint.v1`).
  `destination_id` puede ser un sistema, una estación o una estructura.
  """
  @spec set_waypoint(pos_integer(), String.t(), pos_integer(), keyword()) ::
          {:ok, Response.t()} | {:error, Client.error()}
  def set_waypoint(character_id, token, destination_id, opts \\ []) do
    Client.post("/ui/autopilot/waypoint", nil,
      token: token,
      character_id: character_id,
      group: "ui",
      params: [
        destination_id: destination_id,
        add_to_beginning: Keyword.get(opts, :add_to_beginning, false),
        clear_other_waypoints: Keyword.get(opts, :clear_other_waypoints, false)
      ]
    )
  end

  @doc "Abre en el cliente la ventana de mercado de un tipo (`esi-ui.open_window.v1`)."
  @spec open_market(pos_integer(), String.t(), pos_integer()) ::
          {:ok, Response.t()} | {:error, Client.error()}
  def open_market(character_id, token, type_id) do
    Client.post("/ui/openwindow/marketdetails", nil,
      token: token,
      character_id: character_id,
      group: "ui",
      params: [type_id: type_id]
    )
  end

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
