defmodule Eth.Threat.KillmailTest do
  use ExUnit.Case, async: false

  alias Eth.EngineFixture
  alias Eth.KillmailFixture
  alias Eth.Threat.Killmail

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    :ok = EngineFixture.load_sde(tmp_dir)
  end

  test "normaliza la killmail real de R2Z2" do
    assert {:ok, kill} = Killmail.normalize(KillmailFixture.real())
    assert kill.id == 138_786_136
    assert kill.system_id == 30_004_979
    assert kill.time == ~U[2026-09-29 11:41:53Z]
    assert kill.victim_type_id == 670
    assert kill.attacker_count == 1
    assert kill.attacker_ids == [91_035_048]
    assert kill.value == 10_000.0
    # El locationID no es un stargate del mini SDE.
    assert kill.gate_id == nil
  end

  test "reconoce víctima de transporte, gate con destino, grupos atacantes y arma" do
    raw =
      KillmailFixture.raw(
        system_id: 30_000_142,
        victim_type: 657,
        location_id: 1,
        attackers: [{1, 4_310, 3_561}, {2, 22_456, 22_456}]
      )

    assert {:ok, kill} = Killmail.normalize(raw)
    assert kill.victim_transport
    refute kill.victim_small
    assert kill.gate_id == 1
    assert kill.gate_destination_id == 30_000_144
    assert Enum.sort(kill.attacker_group_ids) == [541, 1_201]
    assert kill.final_blow_weapon_group_id == 72
    refute kill.solo
  end

  test "la cápsula (fuera del mercado) es una víctima chica" do
    assert {:ok, %{victim_small: true, victim_group_id: 29}} =
             Killmail.normalize(KillmailFixture.raw(victim_type: 670))
  end

  test "un gate de otro sistema no cuenta como kill en el gate" do
    assert {:ok, %{gate_id: nil}} =
             Killmail.normalize(KillmailFixture.raw(system_id: 30_000_144, location_id: 1))
  end

  test "marca a CONCORD entre los atacantes" do
    assert {:ok, %{concord: true}} =
             Killmail.normalize(KillmailFixture.raw(attacker_corp: 1_000_125))
  end

  test "descarta NPC e incompletas" do
    assert :npc = Killmail.normalize(KillmailFixture.raw(npc: true))
    assert {:error, :incomplete} = Killmail.normalize(%{"killmail_id" => 1, "esi" => %{}})
    assert {:error, :invalid} = Killmail.normalize(%{"foo" => 1})
  end
end
