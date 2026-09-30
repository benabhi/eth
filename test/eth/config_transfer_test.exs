defmodule Eth.ConfigTransferTest do
  use Eth.DataCase, async: false

  alias Eth.{Accounts, Characters, ConfigTransfer}
  alias Eth.GameRules.Overrides
  alias Eth.Market.Structures

  setup do
    on_exit(fn -> Overrides.reload() end)
    :ok
  end

  test "exporta e importa los parámetros del motor; descarta los inválidos (RF-9.5)" do
    :ok = Accounts.put_engine_params(%{"anti_scam.scam_bid_ratio" => 4.0})
    json = Jason.encode!(ConfigTransfer.export())
    :ok = Accounts.put_engine_params(%{"anti_scam.scam_bid_ratio" => nil})

    config =
      json
      |> Jason.decode!()
      |> put_in(["engine", "no.existe"], 1)

    assert {:ok, summary} = ConfigTransfer.import(config)
    assert "motor" in summary.applied
    assert Enum.any?(summary.skipped, &(&1 =~ "motor: 1"))
    assert Accounts.engine_overrides() == %{"anti_scam.scam_bid_ratio" => 4.0}
  end

  test "exporta y vuelve a importar la configuración sin perder datos" do
    :ok = Accounts.put_game_rule(:sales_tax_base, 0.05)
    :ok = Accounts.put_radar_settings(35.0, [30_002_187])
    :ok = Accounts.put_notification_rule(%{enabled: true, min_tvs: 80, min_profit: 30_000_000})

    {:ok, _} =
      Characters.save_ship_profile(nil, 657, %{cargo_m3: 38_500.0, evasion_class: "industrial"},
        apply_to_hull: true
      )

    {:ok, _} = Structures.follow(1_035_466_617_946)

    exported = ConfigTransfer.export()
    json = Jason.encode!(exported)

    # Nada de secretos en el archivo.
    refute json =~ "refresh"
    refute json =~ "token"

    # Se borra todo y se importa.
    :ok = Accounts.reset_game_rule(:sales_tax_base)
    :ok = Accounts.put_radar_settings(nil, [])
    Enum.each(Characters.list_ship_profiles(), &Characters.delete_ship_profile/1)

    assert {:ok, summary} = ConfigTransfer.import(Jason.decode!(json))
    assert "reglas" in summary.applied
    assert summary.skipped == []

    assert Accounts.game_rule_overrides() == %{sales_tax_base: 0.05}
    assert Accounts.radar_settings() == %{evasive_alpha: 35.0, avoid_system_ids: [30_002_187]}
    assert Accounts.notification_rule().min_tvs == 80
    assert [%{ship_type_id: 657, cargo_m3: 38_500.0}] = Characters.list_ship_profiles()
    assert Structures.get(1_035_466_617_946).followed
  end

  test "descarta lo inválido y lo informa" do
    config = %{
      "app" => "eth",
      "format" => 1,
      "game_rules" => %{"sales_tax_base" => 5, "no_existe" => 0.1},
      "radar" => %{"evasive_alpha" => 500, "avoid_system_ids" => []},
      "ship_profiles" => [%{"ship_type_id" => "657"}]
    }

    assert {:ok, summary} = ConfigTransfer.import(config)
    assert "regla sales_tax_base" in summary.skipped
    assert "regla no_existe" in summary.skipped
    assert "radar (valores fuera de rango)" in summary.skipped
    assert Enum.any?(summary.skipped, &String.starts_with?(&1, "perfil de nave"))
    assert Accounts.game_rule_overrides() == %{}
  end

  test "rechaza archivos que no son de la app" do
    assert {:error, _} = ConfigTransfer.import(%{"hola" => 1})
    assert {:error, _} = ConfigTransfer.import(%{"app" => "eth", "format" => 99})
  end
end
