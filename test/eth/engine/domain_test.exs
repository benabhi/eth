defmodule Eth.Engine.DomainTest do
  use ExUnit.Case, async: true

  alias Eth.Engine.{Fees, Range, Score}

  describe "impuestos (ERS §8.4)" do
    test "sales tax por nivel de Accounting" do
      assert_in_delta Fees.sales_tax(0), 0.075, 1.0e-9
      assert_in_delta Fees.sales_tax(1), 0.06675, 1.0e-9
      assert_in_delta Fees.sales_tax(4), 0.042, 1.0e-9
      assert_in_delta Fees.sales_tax(5), 0.03375, 1.0e-9
      assert Fees.min_sales_tax() == Fees.sales_tax(5)
    end

    test "broker fee NPC con habilidades y standings" do
      assert_in_delta Fees.broker_fee_npc(0, 0, 0), 0.03, 1.0e-9
      assert_in_delta Fees.broker_fee_npc(5, 10, 10), 0.01, 1.0e-9
      # Standings negativos aumentan la comisión.
      assert Fees.broker_fee_npc(5, -10, -10) > Fees.broker_fee_npc(5, 0, 0)
    end
  end

  describe "rango de órdenes de compra (ERS §8.2)" do
    @jita_44 %{location_id: 60_003_760, system_id: 30_000_142, region_id: 10_000_002}
    @jita_other %{location_id: 60_000_001, system_id: 30_000_142, region_id: 10_000_002}
    @perimeter %{location_id: 60_000_002, system_id: 30_000_144, region_id: 10_000_002}
    @amarr %{location_id: 60_008_494, system_id: 30_002_187, region_id: 10_000_043}

    defp jumps(30_000_142, 30_000_144), do: 1
    defp jumps(30_000_144, 30_000_142), do: 1
    defp jumps(a, a), do: 0
    defp jumps(_, _), do: 20

    defp bid(range), do: Map.put(@jita_44, :range, range)

    test "estación, sistema y región" do
      assert Range.covers?(bid(:station), @jita_44, &jumps/2)
      refute Range.covers?(bid(:station), @jita_other, &jumps/2)
      assert Range.covers?(bid(:solarsystem), @jita_other, &jumps/2)
      refute Range.covers?(bid(:solarsystem), @perimeter, &jumps/2)
      assert Range.covers?(bid(:region), @perimeter, &jumps/2)
      refute Range.covers?(bid(:region), @amarr, &jumps/2)
    end

    test "rango en saltos, dentro de la región" do
      assert Range.covers?(bid(1), @perimeter, &jumps/2)
      refute Range.covers?(bid(1), @amarr, &jumps/2)
      assert Range.covers?(bid(5), @jita_other, &jumps/2)
      refute Range.covers?(bid(5), @perimeter, fn _, _ -> nil end)
    end
  end

  describe "tiempo, ISK/h y TVS (ERS §8.9–§8.10)" do
    test "ejemplo del ERS: 11 saltos en industrial + 2 paradas = 910 s y 253M ISK/h" do
      assert Score.travel_seconds(11, 2, :industrial) == 910
      assert_in_delta Score.isk_per_hour(64_000_000, 910), 253_186_813.2, 1.0
      assert Score.travel_seconds(3, 1, :desconocida) == 3 * 45 + 180
      assert Score.isk_per_hour(1_000, 0) == 0.0
    end

    test "normalización y utilidad del ejemplo trabajado (U ≈ 0,86)" do
      assert Score.norm(0, 100) == 0.0
      assert Score.norm(100, 100) == 1.0
      assert Score.norm(1_000, 100) == 1.0

      u =
        Score.utility(%{
          isk_per_hour: 253_000_000,
          profit: 64_000_000,
          roi: 0.057,
          liquidity: 0.9
        })

      assert_in_delta u, 0.86, 0.01
    end

    test "certeza por vigencia de órdenes y frescura de datos" do
      assert_in_delta Score.order_certainty(15.2), 0.919, 0.001
      assert Score.data_certainty(3) == 1.0
      assert_in_delta Score.data_certainty(15), 0.8, 1.0e-9
      assert_in_delta Score.data_certainty(30), 0.6, 1.0e-9
      assert Score.data_certainty(31) == 0.0
      assert Score.tvs(0.86, 0.92) == 79
    end
  end
end
