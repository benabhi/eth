defmodule Eth.KillmailFixture do
  @moduledoc """
  Killmails para tests del radar, sin red (RNF-3.8):

  - `real/0`: una respuesta real de R2Z2 (secuencia 99775276, 2026-09-29), sin cambios;
  - `raw/1`: una killmail sintética con la misma forma, para armar escenarios.

  Sistemas y tipos del mini SDE (`Eth.SdeFixture`): Jita (30000142), Perimeter
  (30000144), Ahbazon (30005196); el stargate 1 está en Jita y lleva a Perimeter.
  """

  @real Path.expand("fixtures/r2z2/killmail_99775276.json", __DIR__)

  @doc "Killmail real de R2Z2 (mapa JSON decodificado)."
  def real, do: @real |> File.read!() |> Jason.decode!()

  @doc """
  Killmail sintética. Opciones: `:id`, `:sequence`, `:time` (DateTime), `:system_id`,
  `:victim_type` (657 Iteron por defecto), `:attackers` (lista de
  `{character_id, ship_type_id, weapon_type_id}`), `:location_id`, `:npc`, `:value`.
  """
  def raw(opts \\ []) do
    id = Keyword.get(opts, :id, System.unique_integer([:positive]))
    time = Keyword.get(opts, :time, DateTime.utc_now()) |> DateTime.truncate(:second)
    attackers = Keyword.get(opts, :attackers, [{9001, 22_456, 22_456}])

    %{
      "killmail_id" => id,
      "hash" => "hash#{id}",
      "sequence_id" => Keyword.get(opts, :sequence, id),
      "uploaded_at" => DateTime.to_unix(time),
      "esi" => %{
        "killmail_id" => id,
        "killmail_time" => DateTime.to_iso8601(time),
        "solar_system_id" => Keyword.get(opts, :system_id, 30_000_142),
        "victim" => %{
          "character_id" => 1234,
          "corporation_id" => 1_000_001,
          "ship_type_id" => Keyword.get(opts, :victim_type, 657)
        },
        "attackers" =>
          attackers
          |> Enum.with_index()
          |> Enum.map(fn {{char, ship, weapon}, i} ->
            %{
              "character_id" => char,
              "corporation_id" => Keyword.get(opts, :attacker_corp, 98_000_001),
              "ship_type_id" => ship,
              "weapon_type_id" => weapon,
              "final_blow" => i == 0
            }
          end)
      },
      "zkb" => %{
        "locationID" => Keyword.get(opts, :location_id, 40_000_001),
        "npc" => Keyword.get(opts, :npc, false),
        "solo" => length(attackers) == 1,
        "totalValue" => Keyword.get(opts, :value, 50_000_000.0)
      }
    }
  end
end
