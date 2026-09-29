defmodule Eth.Threat.Classifier do
  @moduledoc """
  Clasificación de la amenaza de un sistema en alerta (RF-3.6, ERS §8.8). Función pura
  sobre las kills de la ventana. Gana la heurística de mayor confianza:

  | Tipo | Señales |
  |---|---|
  | `:gate_camp` | ≥ 2 kills en el mismo stargate y ≥ 1 atacante repetido entre ellas |
  | `:bubble_camp` | `:gate_camp` en nullsec con Interdictors o HICs entre los atacantes |
  | `:smartbomb_camp` | ≥ 3 cápsulas o naves chicas con golpe final de una Smart Bomb |
  | `:hauler_gank` | highsec, víctima de transporte y ≥ 3 atacantes (más confianza si CONCORD mató a alguno de ellos dentro de los 2 min siguientes) |
  | `:roaming` | cualquier otra alerta |

  Implementa: RF-3.6.
  """

  alias Eth.{GameRules, Sde}
  alias Eth.Threat.Killmail

  @type kind :: :gate_camp | :bubble_camp | :smartbomb_camp | :hauler_gank | :roaming
  @type result :: %{type: kind(), confidence: float(), description: String.t()}

  @concord_window_s 120

  @doc "Clasifica las kills de la ventana de un sistema con seguridad `security`."
  @spec classify([Killmail.t()], float() | nil) :: result()
  def classify(kills, security) do
    groups = GameRules.get(:radar_groups)

    [
      gate_camp(kills, security, groups),
      smartbomb_camp(kills, groups),
      hauler_gank(kills, security),
      roaming(kills)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.max_by(& &1.confidence)
  end

  defp gate_camp(kills, security, groups) do
    kills
    |> Enum.filter(& &1.gate_id)
    |> Enum.group_by(& &1.gate_id)
    |> Enum.map(fn {_gate, at_gate} -> {at_gate, repeated(at_gate)} end)
    |> Enum.filter(fn {at_gate, rep} -> length(at_gate) >= 2 and rep >= 1 end)
    |> Enum.max_by(fn {at_gate, _rep} -> length(at_gate) end, fn -> nil end)
    |> case do
      nil -> nil
      {at_gate, rep} -> camp_result(at_gate, rep, security, groups)
    end
  end

  defp camp_result(at_gate, rep, security, groups) do
    n = length(at_gate)
    to = at_gate |> hd() |> Map.get(:gate_destination_id) |> system_name()

    bubbles? =
      Enum.any?(at_gate, &Enum.any?(&1.attacker_group_ids, fn g -> g in groups.interdictor end))

    if nullsec?(security) and bubbles? do
      %{
        type: :bubble_camp,
        confidence: min(0.7 + 0.05 * n, 0.95),
        description: "Bubble camp en el gate a #{to} · #{n} kills · #{rep} atacantes repetidos"
      }
    else
      %{
        type: :gate_camp,
        confidence: min(0.6 + 0.05 * n, 0.9),
        description: "Gatecamp en el gate a #{to} · #{n} kills · #{rep} atacantes repetidos"
      }
    end
  end

  defp smartbomb_camp(kills, groups) do
    bombed =
      Enum.filter(
        kills,
        &(&1.victim_small and &1.final_blow_weapon_group_id in groups.smart_bomb)
      )

    n = length(bombed)

    if n >= 3 do
      %{
        type: :smartbomb_camp,
        confidence: min(0.7 + 0.05 * n, 0.95),
        description: "Smartbombs: #{n} cápsulas o naves chicas destruidas"
      }
    end
  end

  defp hauler_gank(kills, security) do
    ganks =
      Enum.filter(kills, &(&1.victim_transport and &1.attacker_count >= 3 and not &1.concord))

    if highsec?(security) and ganks != [] do
      concord? = Enum.any?(ganks, &concord_response?(&1, kills))
      biggest = Enum.max_by(ganks, & &1.attacker_count)

      %{
        type: :hauler_gank,
        confidence: if(concord?, do: 0.9, else: 0.7),
        description:
          "Gank de transportes · #{length(ganks)} kills · #{biggest.attacker_count} atacantes" <>
            if(concord?, do: " · CONCORD respondió", else: "")
      }
    end
  end

  # CONCORD mató a alguno de los atacantes dentro de los 2 minutos siguientes.
  defp concord_response?(gank, kills) do
    attackers = MapSet.new(gank.attacker_ids)

    Enum.any?(kills, fn kill ->
      delay = DateTime.diff(kill.time, gank.time, :second)

      kill.concord and delay in 0..@concord_window_s and
        MapSet.member?(attackers, kill.victim_character_id)
    end)
  end

  defp roaming(kills) do
    attackers = kills |> Enum.flat_map(& &1.attacker_ids) |> Enum.uniq() |> length()

    %{
      type: :roaming,
      confidence: 0.5,
      description: "Actividad hostil · #{length(kills)} kills · #{attackers} atacantes"
    }
  end

  # Atacantes (personajes) que aparecen en más de una kill.
  defp repeated(kills) do
    kills
    |> Enum.flat_map(&Enum.uniq(&1.attacker_ids))
    |> Enum.frequencies()
    |> Enum.count(fn {_id, times} -> times > 1 end)
  end

  defp system_name(nil), do: "?"
  defp system_name(id), do: (Sde.system(id) || %{name: "#{id}"}).name

  defp highsec?(nil), do: false
  defp highsec?(security), do: security >= GameRules.get(:highsec_min_security)

  defp nullsec?(nil), do: false
  defp nullsec?(security), do: security <= 0.0
end
