defmodule Eth.Characters.Pilot do
  @moduledoc """
  Vista del piloto activo a partir del contexto de su sesión (RF-5.5 a RF-5.8, RF-6.1):
  lo que muestra la barra del piloto y los parámetros con los que se personaliza el
  Cazador (Accounting real, capital de la billetera, bodega del perfil de la nave, sistema
  actual como base del triángulo y clase de evasión).

  Las funciones que derivan valores (`capital/1`, `evasion_class/1`, `query_overrides/1`)
  son puras; `build/2` solo agrega las búsquedas en el SDE y el perfil de la nave.

  **Bodega** (`ship.cargo_source`), de mayor a menor prioridad:

  1. `:fitting`: calculada con dogma (casco + habilidades + módulos montados según
     `/assets`, que ESI actualiza cada hora);
  2. `:profile`: perfil guardado a mano (RF-5.8);
  3. `:skills`: calculada solo con las habilidades (no se conocen los módulos);
  4. `:sde`: capacidad base del casco, "sin confirmar".

  Implementa: RF-5.5, RF-5.6, RF-5.7, RF-5.8, RF-6.1.
  """

  alias Eth.Characters
  alias Eth.Characters.ShipProfile
  alias Eth.Engine.Fees
  alias Eth.{GameRules, Sde}
  alias Eth.Sde.Dogma

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
          broker_relations: 0..5 | nil,
          standings: %{pos_integer() => float()} | nil,
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
      broker_relations: skill_level(context[:skills], :broker_relations_skill_id),
      standings: context[:standings],
      location: location(context[:location]),
      ship: ship(context[:ship], context),
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

  # Nivel activo de una habilidad cuyo ID está en GameRules (`nil` sin habilidades).
  defp skill_level(nil, _key), do: nil
  defp skill_level(skills, key), do: Map.get(skills, GameRules.get(key), 0)

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
      base_system_id: pilot.location && pilot.location.system_id,
      # Acceso a estructuras del personaje (Certeza de acceso, AS-8).
      character_id: pilot.id
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  @doc """
  Parámetros de `Eth.Engine.StationQuery` que aporta el piloto (RF-4.16): Accounting,
  Broker Relations, standings y capital. Solo lo que ya llegó de ESI.
  """
  @spec station_overrides(t()) :: map()
  def station_overrides(pilot) do
    %{
      accounting: pilot.accounting,
      broker_relations: pilot.broker_relations,
      standings: pilot.standings,
      capital: pilot.capital
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

  defp ship(nil, _context), do: nil

  defp ship(%{ship_type_id: type_id} = ship, context) do
    type = Sde.type(type_id)
    profile = Characters.ship_profile(ship.ship_item_id, type_id)
    calculated = calculated_cargo(ship, type, context)

    evasion =
      if profile,
        do: evasion_atom(profile.evasion_class),
        else: evasion_class(type && type.group_id)

    {cargo_m3, source} = cargo(calculated, profile, type)

    Map.merge(ship, %{
      type_name: (type && type.name) || "#{type_id}",
      group_id: type && type.group_id,
      render_url: ship_render_url(type_id),
      base_capacity: type && type.capacity,
      profile: profile,
      calculated_cargo_m3: calculated && calculated.cargo_m3,
      fitted_modules: calculated && calculated.modules,
      cargo_m3: cargo_m3,
      cargo_source: source,
      cargo_confirmed: source in [:fitting, :profile],
      evasion_class: evasion
    })
  end

  defp cargo(%{source: :fitting} = calculated, _profile, _type),
    do: {calculated.cargo_m3, :fitting}

  defp cargo(_calculated, %ShipProfile{} = profile, _type), do: {profile.cargo_m3, :profile}
  defp cargo(%{source: :skills} = calculated, nil, _type), do: {calculated.cargo_m3, :skills}
  defp cargo(nil, nil, type), do: {base_capacity(type), :sde}

  @doc """
  Bodega calculada con dogma (RF-5.8): `%{cargo_m3, source, modules}` o `nil` si faltan
  las habilidades, la capacidad base o los datos de dogma. `source` es `:fitting` si se
  conocen los módulos montados de esa nave y `:skills` si no.
  """
  @spec calculated_cargo(map(), map() | nil, map()) :: map() | nil
  def calculated_cargo(ship, type, context) do
    with %{} = skills <- context[:skills],
         capacity when is_number(capacity) and capacity > 0 <- type && type.capacity,
         %{} = dogma <- Sde.dogma() do
      modules = context[:assets] && Map.get(context[:assets], ship.ship_item_id)

      fit = %{
        ship_type_id: ship.ship_type_id,
        base_capacity: capacity,
        modules: modules || [],
        skills: skills
      }

      %{
        cargo_m3: Dogma.cargo_capacity(dogma, fit),
        source: if(modules, do: :fitting, else: :skills),
        modules: length(modules || [])
      }
    else
      _ -> nil
    end
  end

  defp base_capacity(%{capacity: capacity}) when capacity > 0, do: capacity
  defp base_capacity(_type), do: nil

  # Conversión segura (sin String.to_atom): solo las clases válidas del perfil.
  defp evasion_atom(class) do
    Enum.find(Map.keys(GameRules.get(:jump_seconds)), :other, &(Atom.to_string(&1) == class))
  end
end
