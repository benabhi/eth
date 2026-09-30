defmodule Eth.Engine.PublishLocations do
  @moduledoc """
  Lugares donde el piloto publica órdenes propias en las familias Por órdenes y Estación
  (RF-4.1, RF-4.16, RF-9.4):

  - los hubs NPC de `:station_trading_location_ids`, con el broker del piloto (Broker
    Relations y standings);
  - las estructuras con broker fee propio en Ajustes → Mercados, con esa comisión (ESI no
    expone el broker de una estructura: lo carga el operador).

  Se lee una vez por evaluación. Si la base no responde, solo quedan los hubs.

  Implementa: RF-9.4.
  """

  alias Eth.{GameRules, Sde}
  alias Eth.Market.Structures

  @type location :: %{
          location_id: pos_integer(),
          system_id: pos_integer(),
          region_id: pos_integer(),
          broker_override: float() | nil
        }

  @doc "Hubs NPC y estructuras con broker propio."
  @spec list() :: [location()]
  def list, do: hubs() ++ structures()

  @doc "Solo los hubs NPC."
  @spec hubs() :: [location()]
  def hubs do
    for id <- GameRules.get(:station_trading_location_ids),
        %{} = station <- [Sde.station(id)],
        do: %{
          location_id: id,
          system_id: station.system_id,
          region_id: station.region_id,
          broker_override: nil
        }
  end

  defp structures do
    for s <- Structures.broker_locations(),
        GameRules.scannable_region?(s.region_id),
        do: %{
          location_id: s.location_id,
          system_id: s.system_id,
          region_id: s.region_id,
          broker_override: s.broker
        }
  rescue
    # Sin base (o sin conexión propia en los tests del motor): solo los hubs.
    _ -> []
  end

  @doc """
  Fuente de mercado de un lugar: la de la estructura si se lee directo, si no la de su
  región (las órdenes de las estructuras públicas también llegan por la región).
  """
  @spec source(location(), (term() -> boolean())) :: term()
  def source(%{location_id: id, region_id: region_id}, has_source?) do
    if has_source?.({:structure, id}), do: {:structure, id}, else: {:region, region_id}
  end
end
