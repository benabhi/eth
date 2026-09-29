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

  @doc """
  Una página de los assets del personaje (`esi-assets.read_assets.v1`, paginado con
  `X-Pages`). Se usa para conocer los módulos montados en sus naves (RF-5.8).
  """
  @spec character_assets(pos_integer(), String.t(), pos_integer(), String.t() | nil) ::
          {:ok, Response.t()} | {:error, Client.error()}
  def character_assets(id, token, page, etag \\ nil) do
    Client.get("/characters/#{id}/assets",
      params: [page: page],
      token: token,
      etag: etag,
      character_id: id,
      group: "char-asset"
    )
  end

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

  @doc "IDs de las estructuras con mercado público (`/universe/structures?filter=market`)."
  @spec public_market_structures(String.t() | nil) ::
          {:ok, Response.t()} | {:error, Client.error()}
  def public_market_structures(etag \\ nil),
    do: Client.get("/universe/structures", params: [filter: "market"], etag: etag)

  @doc """
  Datos de una estructura (`esi-universe.read_structures.v1`): `name`, `owner_id`,
  `solar_system_id` y `type_id`. Un 403 indica que el personaje no tiene acceso.
  """
  @spec structure(pos_integer(), pos_integer(), String.t()) ::
          {:ok, Response.t()} | {:error, Client.error()}
  def structure(structure_id, character_id, token) do
    Client.get("/universe/structures/#{structure_id}",
      token: token,
      character_id: character_id,
      group: "structure"
    )
  end

  @doc """
  Una página de órdenes de una estructura (`esi-markets.structure_markets.v1`,
  `/markets/structures/{id}`). Las órdenes no traen `system_id`: es el de la estructura.
  """
  @spec structure_orders(
          pos_integer(),
          pos_integer(),
          String.t() | nil,
          pos_integer(),
          String.t()
        ) ::
          {:ok, Response.t()} | {:error, Client.error()}
  def structure_orders(structure_id, page, etag, character_id, token) do
    Client.get("/markets/structures/#{structure_id}",
      params: [page: page],
      etag: etag,
      token: token,
      character_id: character_id,
      group: "structure-market"
    )
  end

  @doc """
  Kills de la última hora por sistema (`/universe/system_kills`): `ship_kills`,
  `pod_kills` y `npc_kills`; solo lista los sistemas con actividad (caché de 1 h).
  """
  @spec system_kills(String.t() | nil) :: {:ok, Response.t()} | {:error, Client.error()}
  def system_kills(etag \\ nil), do: Client.get("/universe/system_kills", etag: etag)

  @doc """
  Saltos de la última hora por sistema (`/universe/system_jumps`): `ship_jumps`; solo
  lista los sistemas con tráfico (caché de 1 h).
  """
  @spec system_jumps(String.t() | nil) :: {:ok, Response.t()} | {:error, Client.error()}
  def system_jumps(etag \\ nil), do: Client.get("/universe/system_jumps", etag: etag)

  @doc """
  Precios de referencia globales (`/markets/prices`): `average_price` y `adjusted_price`
  por tipo, en una sola respuesta sin paginar (caché de ESI de 1 h).
  """
  @spec market_prices(String.t() | nil) :: {:ok, Response.t()} | {:error, Client.error()}
  def market_prices(etag \\ nil), do: Client.get("/markets/prices", etag: etag)

  @doc """
  Historial diario de un tipo en una región (`/markets/{region_id}/history`): un día por
  elemento con `date`, `average`, `highest`, `lowest`, `order_count` y `volume`. ESI lo
  actualiza una vez por día (caché hasta el downtime siguiente) y no informa su rate
  limit por cabeceras: el ritmo lo acota `Eth.Market.History` (RF-1.12).
  """
  @spec market_history(pos_integer(), pos_integer()) ::
          {:ok, Response.t()} | {:error, Client.error()}
  def market_history(region_id, type_id),
    do: Client.get("/markets/#{region_id}/history", params: [type_id: type_id])
end
