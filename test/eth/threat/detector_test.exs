defmodule Eth.Threat.DetectorTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Eth.EngineFixture
  alias Eth.Threat.{Classifier, Detector, Killmail}

  @moduletag :tmp_dir
  @now ~U[2026-09-29 12:00:00Z]

  setup %{tmp_dir: tmp_dir} do
    :ok = EngineFixture.load_sde(tmp_dir)
  end

  defp kill(min_ago, attrs \\ []) do
    struct!(
      %Killmail{
        id: System.unique_integer([:positive]),
        time: DateTime.add(@now, -min_ago * 60),
        system_id: 30_000_142
      },
      attrs
    )
  end

  describe "detección (RF-3.5)" do
    test "CA: con λ alto 3 kills no alertan; con λ ≈ 0, 3 kills en un gate sí" do
      refute Detector.alert?(3, 6.0)
      assert Detector.alert?(3, 0.05)
    end

    test "una muerte aislada nunca alerta, aunque λ sea mínimo" do
      refute Detector.alert?(1, 0.05)
      refute Detector.alert?(2, 0.0001)
    end

    test "cola de Poisson" do
      assert Detector.poisson_tail(0, 1.0) == 1.0
      assert_in_delta Detector.poisson_tail(1, 1.0), 1 - :math.exp(-1), 1.0e-12
      assert_in_delta Detector.poisson_tail(3, 0.05), 2.0e-5, 1.0e-6
    end

    property "la cola de Poisson está en [0, 1] y no crece con n" do
      check all(n <- integer(0..30), lambda <- float(min: 0.01, max: 20.0)) do
        tail = Detector.poisson_tail(n, lambda)
        assert tail >= 0.0 and tail <= 1.0
        assert Detector.poisson_tail(n + 1, lambda) <= tail + 1.0e-12
      end
    end

    test "intensidad con decaimiento y multiplicadores" do
      # Una kill ahora (1), una hace 10 min (0,5) y una fuera de la ventana.
      kills = Detector.in_window([kill(0), kill(10), kill(20)], @now)
      assert length(kills) == 2
      assert_in_delta Detector.intensity(kills, @now), 1.5, 1.0e-9

      # Transporte en un gate: ×1,5 × 1,5.
      assert_in_delta Detector.intensity([kill(0, victim_transport: true, gate_id: 1)], @now),
                      2.25,
                      1.0e-9
    end

    test "índice de amenaza acotado entre 0,3 y 1" do
      assert Detector.threat(false, 10.0, 0.1) == 0.0
      assert Detector.threat(true, 3.0, 0.05) == (3.0 - 0.05) / 5.0
      assert Detector.threat(true, 0.5, 0.4) == 0.3
    end
  end

  describe "clasificación (RF-3.6)" do
    test "gatecamp: kills en el mismo gate con atacantes repetidos" do
      kills =
        for i <- 1..3,
            do:
              kill(i, gate_id: 1, gate_destination_id: 30_000_144, attacker_ids: [7, 8, 100 + i])

      assert %{type: :gate_camp, description: description} = Classifier.classify(kills, 0.3)
      assert description == "Gatecamp en el gate a Perimeter · 3 kills · 2 atacantes repetidos"
    end

    test "bubble camp: gatecamp en nullsec con interdictores" do
      kills =
        for i <- 1..3,
            do: kill(i, gate_id: 1, attacker_ids: [7], attacker_group_ids: [541])

      assert %{type: :bubble_camp} = Classifier.classify(kills, -0.4)
      # En lowsec el mismo patrón es un gatecamp.
      assert %{type: :gate_camp} = Classifier.classify(kills, 0.3)
    end

    test "smartbomb camp: cápsulas destruidas por smartbombs" do
      kills =
        for i <- 1..4, do: kill(i, victim_small: true, final_blow_weapon_group_id: 72)

      assert %{type: :smartbomb_camp} = Classifier.classify(kills, 0.9)
    end

    test "hauler gank en highsec; más confianza si CONCORD responde" do
      gank = kill(3, victim_transport: true, attacker_count: 8, attacker_ids: [1, 2, 3])
      assert %{type: :hauler_gank, confidence: 0.7} = Classifier.classify([gank], 0.9)

      concord = kill(2, concord: true, victim_character_id: 2)

      assert %{type: :hauler_gank, confidence: 0.9, description: description} =
               Classifier.classify([gank, concord], 0.9)

      assert description =~ "CONCORD respondió"
      # En lowsec no es un gank de highsec.
      assert %{type: :roaming} = Classifier.classify([gank], 0.3)
    end

    test "cualquier otra alerta es roaming" do
      assert %{type: :roaming, description: "Actividad hostil · 2 kills · 3 atacantes"} =
               Classifier.classify(
                 [kill(1, attacker_ids: [1, 2]), kill(2, attacker_ids: [2, 3])],
                 0.5
               )
    end
  end
end
