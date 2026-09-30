defmodule Eth.GameRules.TunableTest do
  use Eth.DataCase, async: false

  alias Eth.{Accounts, GameRules}
  alias Eth.GameRules.{Overrides, Tunable}
  alias EthWeb.EngineParams

  setup do
    start_supervised!(Overrides)
    :ok
  end

  test "cada parámetro tiene una ruta válida en la configuración y su explicación" do
    for entry <- Tunable.entries() do
      assert Tunable.default(entry) != nil, "#{entry.key} sin valor por defecto"
      assert String.length(entry.help) >= 20, "#{entry.key} sin explicación"

      assert {:ok, _} = Tunable.validate(entry, Tunable.default(entry)),
             "#{entry.key} fuera de rango"
    end
  end

  test "un valor guardado se publica fusionado con el resto de su clave (RF-9.5)" do
    default = GameRules.get(:anti_scam)

    assert :ok =
             Accounts.put_engine_params(%{
               "anti_scam.scam_bid_ratio" => 4.5,
               "staleness_minutes.1" => 20,
               "vulnerability.freighter.gate_camp" => 0.8
             })

    rules = GameRules.get(:anti_scam)
    assert rules.scam_bid_ratio == 4.5
    # El resto del mapa queda con sus valores por defecto.
    assert rules.suspicious_bid_ratio == default.suspicious_bid_ratio
    assert GameRules.get(:staleness_minutes) == {5, 20, 30}
    assert GameRules.get(:vulnerability).freighter.gate_camp == 0.8
    assert GameRules.get(:vulnerability).freighter.roaming == 0.6

    # nil vuelve al valor por defecto.
    assert :ok = Accounts.put_engine_params(%{"anti_scam.scam_bid_ratio" => nil})
    assert GameRules.get(:anti_scam).scam_bid_ratio == default.scam_bid_ratio
  end

  test "valores fuera de rango o claves desconocidas no se guardan" do
    assert {:error, ["anti_scam.scam_bid_ratio"]} =
             Accounts.put_engine_params(%{"anti_scam.scam_bid_ratio" => 0.5})

    assert {:error, ["no.existe"]} = Accounts.put_engine_params(%{"no.existe" => 1})
    assert Accounts.engine_overrides() == %{}
  end

  test "el formulario convierte porcentajes, montos con sufijo y vacíos" do
    pct = Tunable.fetch("tvs_weights.roi")
    isk = Tunable.fetch("tvs_refs.profit")

    assert EngineParams.parse(pct, "20", 0.15) == {:ok, 0.2}
    assert EngineParams.parse(pct, "15", 0.15) == {:ok, nil}
    assert EngineParams.parse(pct, "", 0.15) == {:ok, nil}
    assert EngineParams.parse(isk, "250M", 100_000_000) == {:ok, 250_000_000}
    assert EngineParams.parse(isk, "mucho", 100_000_000) == :error
    assert EngineParams.input(pct, 0.2) == "20"
  end
end
