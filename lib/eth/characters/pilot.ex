defmodule Eth.Characters.Pilot do
  @moduledoc """
  Vista del piloto activo a partir del contexto de su sesión (RF-5.5 a RF-5.8, RF-6.1):
  lo que muestra la barra del piloto y los parámetros con los que se personaliza el
  Cazador (Accounting real, capital de la billetera, bodega del perfil de la nave, sistema
  actual como base del triángulo y clase de evasión).

  Las funciones que derivan valores (`capital/1`, `evasion_class/1`, `query_overrides/1`)
  son puras; `build/2` solo agrega las búsquedas en el SDE y el perfil de la nave.

  Implementa: RF-5.5, RF-5.6, RF-5.7, RF-5.8, RF-6.1.
  """

  alias Eth.Characters
  alias Eth.Characters.ShipProfile
  alias Eth.Engine.Fees
  alias Eth.{GameRules, Sde}

  @images "https://images.evetech.net"

  @type t :: %{
          id: pos_integer(),
          name: String.t() | nil,
          status: atom(),
          online: boolean() | nil,
          portrait_url: String.t(),
          wallet: float() | nil,
          capital: float() | nil,
          accounting: 0..5 | nil,
          sales_tax: float() | nil,
          location: map() | nil,
          ship: map() | nil,
          scopes: [String.t()]
        }

  @doc """
  Arma la vista del piloto desde el contexto público de la sesión (`nil` si todavía no
  hay sesión). `character` aporta nombre y scopes cuando la sesión no arrancó.
  """
  @spec build(map() | nil, Characters.Character.t()) :: t()
  def build(session, character) do
    context = (session && session.context) || %{}
    accounting = accounting_level(context[:skills])

    %{
      id: character.id,
      name: (session && session.name) || character.name,
      status: status(session, character),
      online: context[:online],
      portrait_url: portrait_url(character.id),
      wallet: context[:wallet],
      capital: capital(context[:wallet]),
      accounting: accounting,
      sales_tax: accounting && Fees.sales_tax(accounting),
      location: location(context[:location]),
      ship: ship(context[:ship]),
      scopes: (session && session.scopes) || character.scopes
    }
  end

  @doc "URL del retrato del personaje (servidor de imágenes de CCP)."
  @spec portrait_url(pos_integer(), pos_integer()) :: String.t()
  def portrait_url(character_id, size \\ 64),
    do: "#{@images}/characters/#{character_id}/portrait?size=#{size}"

  @doc "URL del render de un tipo de nave."
  @spec ship_render_url(pos_integer(), pos_integer()) :: String.t()
  def ship_render_url(type_id, size \\ 64), do: "#{@images}/types/#{type_id}/render?size=#{size}"

  @doc "Capital disponible = saldo × porcentaje − reserva (RF-5.5); nunca negativo."
  @spec capital(number() | nil) :: float() | nil
  def capital(nil), do: nil

  def capital(wallet) do
    max(wallet * GameRules.get(:capital_wallet_share) - GameRules.get(:capital_reserve_isk), 0.0)
  end

  @doc "Nivel activo de Accounting (`nil` si las habilidades todavía no se leyeron)."
  @spec accounting_level(map() | nil) :: 0..5 | nil
  def accounting_level(nil), do: nil
  def accounting_level(skills), do: Map.get(skills, GameRules.get(:accounting_skill_id), 0)

  @doc "Clase de evasión sugerida para un grupo de naves del SDE (RF-5.8)."
  @spec evasion_class(pos_integer() | nil) :: atom()
  def evasion_class(group_id),
    do: Map.get(GameRules.get(:ship_group_evasion_classes), group_id, :other)

  @doc """
  Parámetros de `Eth.Engine.Query` que aporta el piloto. Solo incluye lo que se conoce:
  un dato que todavía no llegó de ESI deja el default del modo invitado.
  """
  @spec query_overrides(t()) :: map()
  def query_overrides(pilot) do
    ship = pilot.ship

    %{
      accounting: pilot.accounting,
      capital: pilot.capital,
      cargo_m3: ship && ship.cargo_m3,
      ship_class: ship && ship.evasion_class,
      base_system_id: pilot.location && pilot.location.system_id
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  @doc "¿El piloto tiene el scope pedido?"
  @spec scope?(t(), String.t()) :: boolean()
  def scope?(pilot, scope), do: scope in pilot.scopes

  @doc "¿El piloto está en esa estación o estructura?"
  @spec at_location?(t(), pos_integer()) :: boolean()
  def at_location?(%{location: %{location_id: id}}, id) when not is_nil(id), do: true
  def at_location?(_pilot, _location_id), do: false

  defp status(nil, %{token_status: "relogin"}), do: :relogin
  defp status(nil, _character), do: :starting
  defp status(session, _character), do: session.status

  defp location(nil), do: nil

  defp location(%{solar_system_id: system_id} = loc) do
    system = Sde.system(system_id)
    location_id = loc[:station_id] || loc[:structure_id]
    station = loc[:station_id] && Sde.station(loc.station_id)

    %{
      system_id: system_id,
      system_name: (system && system.name) || "#{system_id}",
      security: system && system.security,
      location_id: location_id,
      docked_name: station && station.name,
      in_structure: not is_nil(loc[:structure_id])
    }
  end

  defp ship(nil), do: nil

  defp ship(%{ship_type_id: type_id} = ship) do
    type = Sde.type(type_id)
    profile = Characters.ship_profile(ship.ship_item_id, type_id)

    ship
    |> Map.merge(%{
      type_name: (type && type.name) || "#{type_id}",
      group_id: type && type.group_id,
      render_url: ship_render_url(type_id),
      base_capacity: type && type.capacity,
      profile: profile
    })
    |> Map.merge(cargo(profile, type))
  end

  # Con perfil: su bodega y su clase. Sin perfil: capacidad base del SDE, sin confirmar.
  defp cargo(%ShipProfile{} = profile, _type) do
    %{
      cargo_m3: profile.cargo_m3,
      cargo_confirmed: true,
      evasion_class: evasion_atom(profile.evasion_class)
    }
  end

  defp cargo(nil, type) do
    %{
      cargo_m3: base_capacity(type),
      cargo_confirmed: false,
      evasion_class: evasion_class(type && type.group_id)
    }
  end

  defp base_capacity(%{capacity: capacity}) when capacity > 0, do: capacity
  defp base_capacity(_type), do: nil

  # Conversión segura (sin String.to_atom): solo las clases válidas del perfil.
  defp evasion_atom(class) do
    Enum.find(Map.keys(GameRules.get(:jump_seconds)), :other, &(Atom.to_string(&1) == class))
  end
end
