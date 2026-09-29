defmodule Eth.Engine.EvaluationTest do
  # Estado global: persistent_term (SDE), tablas con nombre y el Coordinator.
  use Eth.DataCase, async: false

  alias Eth.Engine
  alias Eth.Engine.{Coordinator, Evaluator, Fees, Query, Summary}
  alias Eth.EngineFixture, as: F
  alias Eth.Market.{History, HistoryStats, TableOwner}

  @moduletag :tmp_dir
  @moduletag :capture_log

  @tritanium 34

  setup %{tmp_dir: tmp_dir} do
    :ok = F.load_sde(tmp_dir)
    start_supervised!(TableOwner)
    :ok
  end

  # Evalúa directamente (sin Coordinator), con resúmenes en una tabla propia del test.
  defp evaluate(orders, opts \\ []) do
    if :ets.whereis(:eth_engine_summaries) == :undefined, do: Summary.create_table()
    F.publish_orders(orders)
    [{source, entry}] = TableOwner.all()
    types = Summary.replace(source, entry.tid)

    sources = [
      %{
        source: source,
        tid: entry.tid,
        region_id: 10_000_002,
        last_modified: entry.meta.last_modified
      }
    ]

    Evaluator.run(sources, types,
      tax: Keyword.get(opts, :tax, Fees.sales_tax(4)),
      min_profit: Keyword.get(opts, :min_profit, 1_000)
    )
  end

  describe "evaluador" do
    test "encuentra el arbitraje entre estaciones y recorre el libro" do
      [opp] =
        evaluate([
          {:sell, @tritanium, 4.0, 100_000, F.jita_44(), F.jita(), []},
          {:sell, @tritanium, 4.5, 100_000, F.jita_44(), F.jita(), []},
          {:buy, @tritanium, 5.0, 150_000, F.perimeter_station(), F.perimeter(), []}
        ])

      assert opp.origin.name =~ "Jita IV - Moon 4"
      assert opp.destination.structure
      assert opp.destination.system_name == "Perimeter"
      assert opp.jumps == 1
      assert opp.quantity == 150_000
      # 100k a 4.0 + 50k a 4.5, vendidos a 5.0 con 4,2 % de impuesto.
      assert_in_delta opp.cost, 400_000 + 225_000, 1.0e-6
      assert_in_delta opp.profit, 150_000 * 5.0 * (1 - 0.042) - 625_000, 1.0e-3
      refute opp.remote_sale
    end

    test "una orden con rango región permite vender en el lugar (0 saltos)" do
      opps =
        evaluate([
          {:sell, @tritanium, 4.0, 100_000, F.jita_44(), F.jita(), []},
          {:buy, @tritanium, 5.0, 100_000, F.perimeter_station(), F.perimeter(), range: "region"}
        ])

      in_place = Enum.find(opps, &(&1.destination.location_id == F.jita_44()))
      assert in_place.jumps == 0
      assert in_place.remote_sale
      # La misma orden alcanzada desde Perimeter se descarta como duplicado.
      assert length(opps) == 1
    end

    test "sin margen suficiente después de impuestos no hay oportunidad" do
      assert evaluate([
               {:sell, @tritanium, 4.9, 100_000, F.jita_44(), F.jita(), []},
               {:buy, @tritanium, 5.0, 100_000, F.perimeter_station(), F.perimeter(), []}
             ]) == []
    end
  end

  describe "estructuras (RF-1.6)" do
    test "CA: una orden de estructura que también trae la región no se cuenta dos veces" do
      if :ets.whereis(:eth_engine_summaries) == :undefined, do: Summary.create_table()
      structure = F.perimeter_station()

      # La región trae la venta de Jita y, además, la compra de la estructura.
      F.publish_orders([
        {:sell, @tritanium, 4.0, 100_000, F.jita_44(), F.jita(), []},
        {:buy, @tritanium, 5.0, 50_000, structure, F.perimeter(), []}
      ])

      # La estructura, leída directo, trae la misma orden de compra.
      tid = :ets.new(:eth_orders, [:ordered_set, :public])

      :ets.insert(
        tid,
        Eth.Market.Order.to_row(
          %{
            "order_id" => 2,
            "type_id" => @tritanium,
            "is_buy_order" => true,
            "price" => 5.0,
            "location_id" => structure,
            "system_id" => F.perimeter(),
            "volume_remain" => 50_000,
            "min_volume" => 1,
            "range" => "station",
            "issued" => "2026-09-28T12:00:00Z"
          },
          1
        )
      )

      now = DateTime.utc_now()
      meta = %{last_modified: now, expires: now, region_id: 10_000_002, system_id: F.perimeter()}
      {:ok, _} = TableOwner.publish(tid, {:structure, structure}, meta)

      sources =
        for {source, entry} <- TableOwner.all() do
          Summary.replace(source, entry.tid)
          %{source: source, tid: entry.tid, region_id: 10_000_002, last_modified: now}
        end

      [opp] = Evaluator.run(sources, [@tritanium], tax: Fees.sales_tax(4), min_profit: 1_000)
      assert opp.quantity == 50_000
    end
  end

  describe "consulta personalizada" do
    setup do
      opps =
        evaluate([
          {:sell, @tritanium, 4.0, 100_000, F.jita_44(), F.jita(), []},
          {:buy, @tritanium, 5.0, 100_000, F.perimeter_station(), F.perimeter(), []},
          {:buy, @tritanium, 6.0, 100_000, F.ahbazon_station(), F.ahbazon(), []}
        ])

      {:ok, opps: opps}
    end

    test "en modo Segura descarta destinos fuera de highsec", %{opps: opps} do
      now = DateTime.utc_now()
      {rows, _} = Query.run(opps, %{route_mode: :shortest, cargo_m3: nil, min_profit: 1_000}, now)

      assert Enum.map(rows, & &1.opportunity.destination.system_name) |> Enum.sort() == [
               "Ahbazon",
               "Perimeter"
             ]

      {rows, total} =
        Query.run(opps, %{route_mode: :secure, cargo_m3: nil, min_profit: 1_000}, now)

      assert total == 1
      assert hd(rows).opportunity.destination.system_name == "Perimeter"
    end

    test "la bodega y el capital limitan la cantidad", %{opps: opps} do
      now = DateTime.utc_now()
      params = %{route_mode: :shortest, sort: :profit, min_profit: 1_000}

      {[row | _], _} = Query.run(opps, Map.put(params, :cargo_m3, 100.0), now)
      assert row.quantity == 10_000
      assert_in_delta row.cargo_m3, 100.0, 1.0e-6

      {[row | _], _} =
        Query.run(opps, params |> Map.put(:cargo_m3, nil) |> Map.put(:capital, 40_000), now)

      assert row.quantity == 10_000
    end

    test "calcula triángulo, ISK/h, Certeza y TVS; filtra por texto", %{opps: opps} do
      now = DateTime.utc_now()

      {[row], 1} =
        Query.run(
          opps,
          %{route_mode: :secure, cargo_m3: nil, min_profit: 1_000, search: "perímeter"},
          now
        )

      # Piloto en Jita (sistema base): 0 saltos al origen, 1 al destino.
      assert row.jumps_to_origin == 0
      assert row.total_jumps == 1
      assert row.seconds == 50 + 2 * 180
      assert row.isk_per_hour > 0
      # Órdenes vigentes al llegar (410 s) × datos frescos × sin historial (0,7) × acceso a
      # estructura (0,9) × ruta (2 sistemas highsec con el riesgo base del prior: 0,0005 ×
      # V[industrial][roaming] 0,5).
      route = (1 - 0.0005 * 0.5) ** 2
      assert_in_delta row.breakdown.route_certainty, route, 1.0e-9
      assert_in_delta row.certainty, :math.exp(-(410 / 60) / 180) * 0.7 * 0.9 * route, 1.0e-6
      assert row.route_path == [F.jita(), F.perimeter()]
      assert row.breakdown.access_certainty == 0.9
      assert row.shield.status == :no_history
      assert row.tvs in 1..100

      assert {[], 0} = Query.run(opps, %{route_mode: :secure, search: "amarr"}, now)
    end

    test "un sistema a evitar deja fuera las rutas que no tienen alternativa", %{opps: opps} do
      now = DateTime.utc_now()
      params = %{route_mode: :shortest, cargo_m3: nil, min_profit: 1_000}

      {rows, 2} = Query.run(opps, params, now)
      assert length(rows) == 2

      # Perimeter está entre Jita y Ahbazon: sin él no hay camino a Ahbazon. Como destino,
      # Perimeter sigue permitido.
      {[row], 1} = Query.run(opps, Map.put(params, :avoid, MapSet.new([F.perimeter()])), now)
      assert row.opportunity.destination.system_id == F.perimeter()
    end

    test "una alerta en el camino baja la Certeza y se informa; Evasiva la considera", %{
      opps: opps
    } do
      now = DateTime.utc_now()

      risk = %{
        base_risk: %{},
        quiet: %{highsec: 0.0, lowsec: 0.0, nullsec: 0.0},
        alerts: %{
          F.perimeter() => %{
            system_id: F.perimeter(),
            threat: 0.9,
            kills: 5,
            classification: %{type: :gate_camp, description: "Gatecamp"}
          }
        },
        degraded: false
      }

      params = %{cargo_m3: nil, min_profit: 1_000, search: "perimeter", risk: risk}

      for mode <- [:secure, :evasive] do
        {[row], 1} = Query.run(opps, Map.put(params, :route_mode, mode), now)
        assert row.route_alerts.count == 1
        assert row.route_alerts.worst.classification.type == :gate_camp
        # Industrial: V[gate_camp] = 0,85 → p = 0,765.
        assert_in_delta row.breakdown.route_certainty, 1 - 0.765, 1.0e-9
      end
    end
  end

  describe "anti-scam y liquidez en la consulta (RF-4.7, RF-4.8)" do
    setup do
      start_supervised!(History)
      :ok
    end

    # Historial estable de 30 días en The Forge (origen y destino de los fixtures).
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

    test "margin trading scam: se oculta por defecto y, si se muestra, queda con TVS 0" do
      put_history(4.5, 1_000_000)

      opps =
        evaluate([
          {:sell, @tritanium, 4.0, 100_000, F.jita_44(), F.jita(), []},
          {:buy, @tritanium, 50.0, 100_000, F.perimeter_station(), F.perimeter(), []}
        ])

      now = DateTime.utc_now()
      params = %{route_mode: :secure, cargo_m3: nil, min_profit: 1_000}

      assert {[], 0} = Query.run(opps, params, now)

      {[row], 1} = Query.run(opps, Map.put(params, :shield, :all), now)
      assert row.shield.status == :scam
      assert "Compra a 11,1× la mediana de 7 días" in row.shield.reasons
      assert row.certainty == 0.0
      assert row.tvs == 0
    end

    test "oportunidad legítima: ok, Certeza completa y liquidez del historial" do
      put_history(4.8, 50_000)

      opps =
        evaluate([
          {:sell, @tritanium, 4.0, 100_000, F.jita_44(), F.jita(), []},
          {:buy, @tritanium, 5.0, 100_000, F.perimeter_station(), F.perimeter(), []}
        ])

      {[row], 1} =
        Query.run(
          opps,
          %{route_mode: :secure, cargo_m3: nil, min_profit: 1_000},
          DateTime.utc_now()
        )

      assert row.shield.status == :ok
      assert row.breakdown.scam_certainty == 1.0
      # 100.000 unidades frente a 50.000 por día: log10(1 + 9 × 0,5).
      assert_in_delta row.breakdown.liquidity, :math.log10(5.5), 1.0e-9
      refute row.illiquid
      assert row.history.destination.days_traded_30d == 30

      assert [{{10_000_002, @tritanium}, dest}, {{10_000_002, @tritanium}, origin}] =
               Coordinator.history_demand(opps)

      assert dest > origin
    end
  end

  test "el Coordinator evalúa cada snapshot nuevo y publica una versión" do
    Phoenix.PubSub.subscribe(Eth.PubSub, Coordinator.topic())
    start_supervised!({Task.Supervisor, name: Eth.Engine.TaskSupervisor})
    start_supervised!(Coordinator)

    F.publish_orders([
      {:sell, @tritanium, 4.0, 10_000_000, F.jita_44(), F.jita(), []},
      {:buy, @tritanium, 5.0, 10_000_000, F.perimeter_station(), F.perimeter(), []}
    ])

    assert_receive {:opportunities_updated, %{version: 1, opportunities: 1}}, 5_000
    assert [%{type_name: "Tritanium"}] = Engine.all()
    assert {[_row], 1} = Engine.query(%{cargo_m3: nil})

    # Un snapshot nuevo sin cruce rentable deja la lista vacía (versión 2).
    F.publish_orders([{:sell, @tritanium, 4.0, 100_000, F.jita_44(), F.jita(), []}])
    assert_receive {:opportunities_updated, %{version: 2, opportunities: 0}}, 5_000
    assert Engine.all() == []
  end
end
