defmodule Eth.Engine.RouteRiskTest do
  use ExUnit.Case, async: false

  alias Eth.EngineFixture
  alias Eth.Engine.{RouteRisk, Score}

  @moduletag :tmp_dir

  @jita 30_000_142
  @perimeter 30_000_144
  @ahbazon 30_005_196

  setup %{tmp_dir: tmp_dir} do
    :ok = EngineFixture.load_sde(tmp_dir)
  end

  defp ctx(alerts, opts \\ []) do
    %{
      base_risk: Keyword.get(opts, :base_risk, %{}),
      quiet: %{highsec: 0.0, lowsec: 0.0, nullsec: 0.0},
      alerts: alerts,
      degraded: Keyword.get(opts, :degraded, false)
    }
  end

  defp alert(system_id, threat, type) do
    %{system_id => %{threat: threat, kills: 4, classification: %{type: type, description: ""}}}
  end

  describe "ejemplo trabajado de §8.9 (criterio de aceptación de F6)" do
    # U = 0,86; resto de los factores = 0,92; la ruta cruza un hauler_gank con amenaza 0,8.
    @utility 0.86
    @other 0.92

    defp tvs(ship_class, cargo_value) do
      c_route =
        RouteRisk.certainty(
          [@jita, @perimeter],
          ship_class,
          cargo_value,
          ctx(alert(@perimeter, 0.8, :hauler_gank))
        )

      Score.tvs(@utility, @other * c_route)
    end

    test "reproduce la tabla: la clase de nave y el valor de la carga cambian el TVS" do
      assert RouteRisk.attractiveness(3.1e9) |> Float.round(2) == 0.83
      assert tvs(:freighter, 3.1e9) == 32
      assert tvs(:industrial, 3.1e9) == 42
      assert tvs(:deep_space_transport, 3.1e9) == 61
      assert tvs(:blockade_runner, 3.1e9) == 71
      # Freighter con la carga dividida (500M).
      assert tvs(:freighter, 5.0e8) == 47
    end

    test "un gatecamp en lowsec con un Iteron deja C_ruta ≈ 0,24 (mockup de §9.3)" do
      c =
        RouteRisk.certainty([@ahbazon], :industrial, 1.0e8, ctx(alert(@ahbazon, 0.9, :gate_camp)))

      assert_in_delta c, 0.235, 0.01
    end
  end

  test "atractivo de la carga" do
    assert RouteRisk.attractiveness(1.0e7) == 0.05
    assert_in_delta RouteRisk.attractiveness(1.0e8), 1 / 3, 1.0e-9
    assert RouteRisk.attractiveness(1.0e10) == 1.0
    assert RouteRisk.attractiveness(0) == 0.05
  end

  test "sin alertas, el riesgo base por salto pesa según la clase de nave" do
    c = ctx(%{}, base_risk: %{@ahbazon => 0.1})
    # Industrial: V[roaming] = 0,5 → p = 0,05.
    assert_in_delta RouteRisk.certainty([@jita, @ahbazon], :industrial, 1.0e9, c), 0.95, 1.0e-9

    assert_in_delta RouteRisk.certainty([@jita, @ahbazon], :blockade_runner, 1.0e9, c),
                    0.99,
                    1.0e-9
  end

  test "con el radar degradado penaliza los sistemas low/null" do
    penalty = Eth.GameRules.get(:radar).degraded_penalty

    assert RouteRisk.certainty([@jita, @ahbazon], :industrial, 0, ctx(%{}, degraded: true)) ==
             penalty

    assert RouteRisk.certainty([@jita, @perimeter], :industrial, 0, ctx(%{}, degraded: true)) ==
             1.0
  end

  test "detalle por sistema con la alerta" do
    [jita, ahbazon] =
      RouteRisk.details(
        [@jita, @ahbazon],
        :industrial,
        1.0e8,
        ctx(alert(@ahbazon, 0.9, :gate_camp))
      )

    assert jita.name == "Jita" and jita.type == nil
    assert ahbazon.type == :gate_camp and ahbazon.kills == 4
    assert_in_delta ahbazon.probability, 0.765, 1.0e-9
  end
end
