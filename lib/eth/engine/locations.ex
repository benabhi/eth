defmodule Eth.Engine.Locations do
  @moduledoc """
  Descripción de ubicaciones de mercado para las oportunidades: estaciones NPC con su
  nombre del SDE y estructuras Upwell (su nombre requiere autenticación: F7).
  """

  alias Eth.Sde

  @type t :: %{
          location_id: pos_integer(),
          name: String.t(),
          structure: boolean(),
          system_id: pos_integer(),
          system_name: String.t() | nil,
          region_id: pos_integer() | nil,
          region_name: String.t() | nil,
          security: float() | nil
        }

  @doc "Describe una ubicación a partir de su ID y sistema."
  @spec describe(pos_integer(), pos_integer()) :: t()
  def describe(location_id, system_id) do
    system = Sde.system(system_id)
    region_id = system && system.region_id
    station = Sde.station(location_id)

    %{
      location_id: location_id,
      name: (station && station.name) || structure_name(location_id, system),
      structure: station == nil,
      system_id: system_id,
      system_name: system && system.name,
      region_id: region_id,
      region_name: region_id && (Sde.region(region_id) || %{name: nil}).name,
      security: system && system.security
    }
  end

  defp structure_name(location_id, nil), do: "Estructura #{location_id}"
  defp structure_name(location_id, system), do: "#{system.name} · Estructura #{location_id}"
end
