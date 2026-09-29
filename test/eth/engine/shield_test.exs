defmodule Eth.Engine.ShieldTest do
  use ExUnit.Case, async: true

  alias Eth.Engine.{Liquidity, Shield}
  alias Eth.Market.HistoryStats

  @as_of ~D[2026-09-28]
  @now ~U[2026-09-29 12:00:00Z]

  # Historial estable: `days` días seguidos a `price` con `volume` unidades por día.
  defp stable(price, days \\ 30, volume \\ 1_000) do
    0..(days - 1)
    |> Enum.map(fn offset ->
      %{
        "date" => Date.to_iso8601(Date.add(@as_of, -offset)),
        "average" => price,
        "volume" => volume
      }
    end)
    |> HistoryStats.compute(@as_of)
  end

  defp input(overrides) do
    Map.merge(
      %{
        bid: 110.0,
        ask: 100.0,
        roi: 0.06,
        bid_min_volume: 1,
        bid_issued: ~U[2026-09-20 00:00:00Z],
        dest_stats: stable(105.0),
        origin_stats: stable(100.0),
        global_average: 104.0,
        now: @now
      },
      Map.new(overrides)
    )
  end

  describe "criterios de aceptación (RF-4.8)" do
    test "margin trading scam: compra inflada 11× y venta inflada ⇒ scam" do
      verdict =
        Shield.evaluate(
          input(bid: 1_155.0, ask: 900.0, roi: 0.25, bid_issued: ~U[2026-09-29 11:22:00Z])
        )

      assert verdict.status == :scam
      assert "Compra a 11,0× la mediana de 7 días" in verdict.reasons
      assert "Venta en el origen a 9,0× la mediana de 7 días" in verdict.reasons
      assert "Orden creada hace 38 min" in verdict.reasons
      assert Shield.certainty(verdict.status) == 0.0
    end

    test "oportunidad legítima con historial estable ⇒ ok" do
      assert %{status: :ok, reasons: []} = Shield.evaluate(input([]))
    end
  end

  describe "reglas" do
    test "AS-2: compra entre 1,5× y 3× la mediana ⇒ sospechoso" do
      assert %{status: :suspicious, reasons: ["Compra a 2,0× la mediana de 7 días"]} =
               Shield.evaluate(input(bid: 210.0))
    end

    test "AS-4: venta del origen inflada junto con AS-2 ⇒ scam" do
      assert %{status: :scam} = Shield.evaluate(input(bid: 210.0, ask: 160.0))
    end

    test "AS-5: volumen mínimo junto con AS-2 ⇒ scam" do
      verdict = Shield.evaluate(input(bid: 210.0, bid_min_volume: 50))
      assert verdict.status == :scam
      assert "La compra exige al menos 50 unidades por transacción" in verdict.reasons
    end

    test "AS-6: orden recién creada junto con AS-2 ⇒ scam; sin AS-2 no cuenta" do
      fresh = ~U[2026-09-29 11:00:00Z]
      assert %{status: :scam} = Shield.evaluate(input(bid: 210.0, bid_issued: fresh))
      assert %{status: :ok} = Shield.evaluate(input(bid_issued: fresh))
    end

    test "AS-3: sin historial, compra muy por encima del precio global ⇒ sospechoso" do
      verdict = Shield.evaluate(input(dest_stats: nil, bid: 600.0))
      assert verdict.status == :suspicious
      assert "Compra a 5,8× el precio promedio global" in verdict.reasons
    end

    test "AS-7: pocos días operados ⇒ sin historial; con ROI extremo ⇒ sospechoso" do
      scarce = stable(105.0, 2)

      assert %{status: :no_history, reasons: ["Historial escaso: 2 días con operaciones en 30"]} =
               Shield.evaluate(input(dest_stats: scarce))

      assert %{status: :suspicious} = Shield.evaluate(input(dest_stats: scarce, roi: 1.5))
      assert %{status: :no_history} = Shield.evaluate(input(dest_stats: nil))
    end

    test "con pocos días en la última semana usa la mediana de 30 días" do
      # 10 días a 100 hace dos semanas y ninguno en los últimos 7.
      stats =
        10..19
        |> Enum.map(
          &%{"date" => Date.to_iso8601(Date.add(@as_of, -&1)), "average" => 100.0, "volume" => 5}
        )
        |> HistoryStats.compute(@as_of)

      assert %{status: :suspicious, reasons: ["Compra a 2,0× la mediana de 30 días"]} =
               Shield.evaluate(input(dest_stats: stats, bid: 200.0))
    end

    test "severidad de los estados" do
      assert Shield.worse?(:scam, :suspicious)
      assert Shield.worse?(:suspicious, :no_history)
      refute Shield.worse?(:ok, :no_history)
    end
  end

  describe "liquidez (RF-4.7)" do
    test "índice según el volumen diario frente a la cantidad" do
      stats = stable(100.0, 30, 1_000)
      assert Liquidity.index(stats, 1_000) == 1.0
      assert Liquidity.index(stats, 500) == 1.0
      assert_in_delta Liquidity.index(stats, 10_000), :math.log10(1.9), 1.0e-9
      assert Liquidity.index(nil, 100) == 0.5
    end

    test "ilíquido con menos de 5 días operados en 30" do
      assert Liquidity.illiquid?(stable(100.0, 4))
      refute Liquidity.illiquid?(stable(100.0, 5))
      refute Liquidity.illiquid?(nil)
    end
  end
end
