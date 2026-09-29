defmodule Eth.Engine.StationTradingTest do
  use Eth.DataCase, async: false

  alias Eth.Engine.{StationEvaluator, StationQuery, StationTrading, Summary}
  alias Eth.EngineFixture, as: F
  alias Eth.Market.{History, HistoryStats, TableOwner}

  @moduletag :tmp_dir
  @moduletag :capture_log

  @tritanium 34
  # Modo invitado: Accounting IV (4,2 %) y Broker Relations IV sin standings (1,8 %).
  @fees %{tax: 0.042, broker: 0.018}

  defp order(price, volume, id, min_volume \\ 1), do: {price / 1, volume, id, 0, min_volume}

  describe "cálculo puro (RF-4.16)" do
    test "cotiza precios legales y el margen neto con broker ×2 y sales tax" do
      book = %{bids: [order(4.0, 1_000, 1)], asks: [order(5.0, 1_000, 2)]}
      q = StationTrading.quote(book, @fees)

      assert q.buy_price == 4.01
      assert q.sell_price == 4.99
      assert_in_delta q.unit_cost, 4.01 * 1.018, 1.0e-9
      assert_in_delta q.unit_revenue, 4.99 * (1 - 0.042 - 0.018), 1.0e-9
      assert_in_delta q.margin_pct, (4.99 * 0.94 - 4.01 * 1.018) / (4.01 * 1.018), 1.0e-9
    end

    test "sin margen o sin un lado no hay cotización" do
      assert StationTrading.quote(%{bids: [order(4.9, 1, 1)], asks: [order(5.0, 1, 2)]}, @fees) ==
               nil

      assert StationTrading.quote(%{bids: [], asks: [order(5.0, 1, 2)]}, @fees) == nil
    end

    test "las órdenes propias no cuentan: se supera a la siguiente" do
      book = %{
        bids: [order(4.5, 10, 1), order(4.0, 10, 2)],
        asks: [order(5.0, 10, 3), order(5.5, 10, 4)]
      }

      q = StationTrading.quote(book, @fees, MapSet.new([1, 3]))
      assert q.best_bid == 4.0
      assert q.best_ask == 5.5
    end

    test "competencia dentro de la banda y su Certeza" do
      book = %{
        bids: [order(4.0, 1, 1), order(3.9, 1, 2), order(2.0, 1, 3)],
        asks: [order(5.0, 1, 4)]
      }

      q = StationTrading.quote(book, @fees)
      # ±5 % de 4,01: 4,00 y 3,90 entran; 2,00 no.
      assert q.competition == %{bids: 2, asks: 1}
      assert StationTrading.competition_certainty(%{bids: 0, asks: 0}) == 1.0
      assert StationTrading.competition_certainty(%{bids: 10, asks: 3}) == 0.5
    end

    test "el plan usa una parte del volumen diario y lo acota el capital (escrow 100 %)" do
      q = StationTrading.quote(%{bids: [order(4.0, 1, 1)], asks: [order(5.0, 1, 2)]}, @fees)

      # 10 % de 1.000.000 por día.
      assert %{quantity: 100_000} = StationTrading.plan(q, 1_000_000, nil)

      plan = StationTrading.plan(q, 1_000_000, 40_000)
      assert plan.quantity == floor(40_000 / q.unit_cost)
      assert_in_delta plan.profit_day, plan.quantity * q.unit_margin, 1.0e-6
      assert StationTrading.plan(q, nil, nil).quantity == 0
    end
  end

  describe "evaluación universal y consulta" do
    setup %{tmp_dir: tmp_dir} do
      :ok = F.load_sde(tmp_dir)
      start_supervised!(TableOwner)
      start_supervised!(History)
      if :ets.whereis(:eth_engine_summaries) == :undefined, do: Summary.create_table()
      :ok
    end

    defp evaluate(orders) do
      F.publish_orders(orders)
      [{source, entry} = pair] = TableOwner.all()
      types = Summary.replace(source, entry.tid)
      StationEvaluator.run([pair], %{source => types})
    end

    defp put_history(price, volume) do
      as_of = HistoryStats.last_day(DateTime.utc_now())

      stats =
        0..29
        |> Enum.map(
          &%{
            "date" => Date.to_iso8601(Date.add(as_of, -&1)),
            "average" => price,
            "volume" => volume
          }
        )
        |> HistoryStats.compute(as_of)

      :ets.insert(:eth_history_stats, {{10_000_002, @tritanium}, stats})
    end

    test "candidato en Jita 4-4 con su libro; las órdenes de otras estaciones no cuentan" do
      [opp] =
        evaluate([
          {:buy, @tritanium, 4.0, 1_000_000, F.jita_44(), F.jita(), []},
          {:buy, @tritanium, 4.6, 1_000_000, F.perimeter_station(), F.perimeter(), []},
          {:sell, @tritanium, 5.0, 1_000_000, F.jita_44(), F.jita(), []},
          {:sell, @tritanium, 5.2, 500_000, F.jita_44(), F.jita(), []}
        ])

      assert opp.location.location_id == F.jita_44()
      assert [{4.0, 1_000_000, _, _, 1}] = opp.bids
      assert [{5.0, _, _, _, _}, {5.2, _, _, _, _}] = opp.asks
    end

    test "sin historial no se propone; con historial estable, sí" do
      opps =
        evaluate([
          {:buy, @tritanium, 4.0, 1_000_000, F.jita_44(), F.jita(), []},
          {:sell, @tritanium, 5.0, 1_000_000, F.jita_44(), F.jita(), []}
        ])

      now = DateTime.utc_now()
      assert {[], 0} = StationQuery.run(opps, %{}, now)

      put_history(4.5, 1_000_000)
      {[row], 1} = StationQuery.run(opps, %{capital: 1_000_000_000}, now)

      assert row.quote.buy_price == 4.01
      assert row.quote.sell_price == 4.99
      assert_in_delta row.broker_rate, 0.018, 1.0e-12
      assert row.shield.status == :ok
      assert row.plan.quantity == 100_000
      assert row.profit_day > 0
    end

    test "una compra muy por encima de la mediana es la firma del scam: se oculta" do
      put_history(4.5, 1_000_000)

      opps =
        evaluate([
          {:buy, @tritanium, 50.0, 1_000_000, F.jita_44(), F.jita(), []},
          {:sell, @tritanium, 80.0, 1_000_000, F.jita_44(), F.jita(), []}
        ])

      now = DateTime.utc_now()
      assert {[], 0} = StationQuery.run(opps, %{}, now)
      {[row], 1} = StationQuery.run(opps, %{shield: :all}, now)
      assert row.shield.status == :scam
      assert row.certainty == 0.0
    end

    test "los standings con la corporación dueña y su facción bajan el broker" do
      # Jita 4-4: Caldari Navy (1000035) de la facción Caldari State (500001).
      fees =
        StationQuery.fees(
          F.jita_44(),
          Map.merge(StationQuery.defaults(), %{standings: %{1_000_035 => 10.0, 500_001 => 10.0}})
        )

      assert_in_delta fees.broker, 0.03 - 0.012 - 0.003 - 0.002, 1.0e-12
    end
  end
end
