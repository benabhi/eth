defmodule Eth.Threat.Killmail do
  @moduledoc """
  Killmail normalizada para el radar (RF-3.2). Función pura sobre el JSON de R2Z2
  (`killmail_id`, `esi` con la killmail de ESI y `zkb` con los metadatos de zKillboard).

  Por kill guarda solo lo que usan el mapa de calor y la clasificación (§8.8): sistema,
  hora, víctima (grupo y si es de transporte o chica), atacantes (personajes, corporaciones,
  alianzas y grupos de sus naves), golpe final y su arma, stargate donde ocurrió (con el
  sistema al que lleva), valor y marcas `solo`/CONCORD. Las kills NPC (`zkb.npc`) se
  descartan.

  Implementa: RF-3.2.
  """

  alias Eth.{GameRules, Sde}

  @enforce_keys [:id, :time, :system_id]
  defstruct [
    :id,
    :time,
    :system_id,
    :victim_type_id,
    :victim_character_id,
    :victim_group_id,
    :gate_id,
    :gate_destination_id,
    :final_blow_weapon_group_id,
    :value,
    victim_transport: false,
    victim_small: false,
    attacker_count: 0,
    attacker_ids: [],
    attacker_group_ids: [],
    concord: false,
    solo: false
  ]

  @type t :: %__MODULE__{
          id: pos_integer(),
          time: DateTime.t(),
          system_id: pos_integer(),
          victim_type_id: pos_integer() | nil,
          victim_character_id: pos_integer() | nil,
          victim_group_id: pos_integer() | nil,
          victim_transport: boolean(),
          victim_small: boolean(),
          gate_id: pos_integer() | nil,
          gate_destination_id: pos_integer() | nil,
          final_blow_weapon_group_id: pos_integer() | nil,
          value: float() | nil,
          attacker_count: non_neg_integer(),
          attacker_ids: [pos_integer()],
          attacker_group_ids: [pos_integer()],
          concord: boolean(),
          solo: boolean()
        }

  @doc """
  Normaliza un killmail de R2Z2: `{:ok, kill}`, `:npc` (se ignora) o `{:error, motivo}` si
  le faltan datos esenciales.
  """
  @spec normalize(map()) :: {:ok, t()} | :npc | {:error, atom()}
  def normalize(%{"zkb" => %{"npc" => true}}), do: :npc

  def normalize(%{"killmail_id" => id, "esi" => esi} = raw) when is_map(esi) do
    with {:ok, time, _} <- DateTime.from_iso8601(esi["killmail_time"] || ""),
         system_id when is_integer(system_id) <- esi["solar_system_id"] do
      {:ok, build(id, time, system_id, esi, raw["zkb"] || %{})}
    else
      _ -> {:error, :incomplete}
    end
  end

  def normalize(_other), do: {:error, :invalid}

  defp build(id, time, system_id, esi, zkb) do
    groups = GameRules.get(:radar_groups)
    victim = esi["victim"] || %{}
    attackers = esi["attackers"] || []
    victim_group = victim["ship_type_id"] && Sde.type_group(victim["ship_type_id"])
    gate = zkb["locationID"] && gate(zkb["locationID"], system_id)
    final = Enum.find(attackers, & &1["final_blow"]) || %{}

    %__MODULE__{
      id: id,
      time: time,
      system_id: system_id,
      victim_type_id: victim["ship_type_id"],
      victim_character_id: victim["character_id"],
      victim_group_id: victim_group,
      victim_transport: victim_group in groups.transport,
      victim_small: victim_group in groups.small,
      gate_id: gate && zkb["locationID"],
      gate_destination_id: gate && gate.destination_system_id,
      final_blow_weapon_group_id:
        final["weapon_type_id"] && Sde.type_group(final["weapon_type_id"]),
      value: zkb["totalValue"] && zkb["totalValue"] / 1,
      attacker_count: length(attackers),
      attacker_ids: attackers |> Enum.map(& &1["character_id"]) |> Enum.reject(&is_nil/1),
      attacker_group_ids:
        attackers
        |> Enum.map(&(&1["ship_type_id"] && Sde.type_group(&1["ship_type_id"])))
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq(),
      concord:
        Enum.any?(attackers, &(&1["corporation_id"] == GameRules.get(:concord_corporation_id))),
      solo: zkb["solo"] == true
    }
  end

  @doc "Mapa JSON de la kill normalizada (para guardarla en disco sin `binary_to_term`)."
  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = kill) do
    kill |> Map.from_struct() |> Map.update!(:time, &DateTime.to_iso8601/1)
  end

  @doc "Kill normalizada a partir de `to_json/1` (`nil` si el mapa no es válido)."
  @spec from_json(map()) :: t() | nil
  def from_json(%{"id" => id, "time" => time, "system_id" => system_id} = map) do
    {:ok, time, _} = DateTime.from_iso8601(time)
    fields = Map.keys(%__MODULE__{id: 0, time: nil, system_id: 0}) -- [:__struct__]

    attrs =
      for field <- fields,
          key = Atom.to_string(field),
          Map.has_key?(map, key),
          into: %{},
          do: {field, map[key]}

    struct!(__MODULE__, %{attrs | id: id, time: time, system_id: system_id})
  rescue
    _error -> nil
  end

  def from_json(_other), do: nil

  # El locationID de zKillboard es el celeste más cercano: solo interesa si es un stargate
  # del mismo sistema.
  defp gate(location_id, system_id) do
    case Sde.stargate(location_id) do
      %{system_id: ^system_id} = gate -> gate
      _ -> nil
    end
  end
end
