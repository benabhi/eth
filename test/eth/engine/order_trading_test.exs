defmodule Eth.Engine.OrderTradingTest do
  use Eth.DataCase, async: false

  alias Eth.Engine.{OrderEvaluator, OrderQuery, Summary}
  alias Eth.EngineFixture, as: F
  alias Eth.Market.{History, HistoryStats, TableOwner}

  @moduletag :tmp_dir
  @moduletag :capture_log

  @tritanium 34

  setup %{tmp_dir: tmp_dir} do
    :ok = F.load_sde(tmp_dir)
    start_supervised!(TableOwner)
    start_supervised!(History)
    if :ets.whereis(:eth_engine_summaries) == :undefined, do: Summary.create_table()
    :ok
  end

  # Historial estable en The Forge: mediana 5 ISK y 2.000.000 unidades por día.
  defp put_history do
    as_of = HistoryStats.last_day(DateTime.utc_now())

    stats =
      0..29
      |> Enum.map(
        &%{
          "date" => Date.to_iso8601(Date.add(as_of, -&1)),
          "average" => 5.0,
          "volume" => 2_000_000
        }
      )
      |> HistoryStats.compute(as_of)

    :ets.insert(:eth_history_stats, {{10_000_002, @tritanium}, stats})
  end

  defp evaluate(orders) do
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

    OrderEvaluator.run(sources, types)
  end

  test "Listado: comprar barato en Perimeter y publicar la venta en Jita 4-4" do
    put_history()

    %{candidates: opps} =
      evaluate([
        {:sell, @tritanium, 5.5, 1_000_000, F.jita_44(), F.jita(), []},
        {:sell, @tritanium, 4.0, 2_000_000, F.perimeter_npc(), F.perimeter(), []}
      ])

    {[row], 1} = OrderQuery.run(opps, %{mode: :listing}, DateTime.utc_now())

    assert row.mode == :listing
    assert row.opportunity.origin.location_id == F.perimeter_npc()
    assert row.opportunity.destination.location_id == F.jita_44()
    # Supera a la mejor venta del hub con un precio legal.
    assert row.price == 5.49
    # Tope del mercado: 2.000.000/día × 10 % × 7 días.
    assert row.quantity == 1_400_000
    assert_in_delta row.days, 7.0, 1.0e-9
    assert_in_delta row.profit, 1_400_000 * (5.49 * (1 - 0.042 - 0.018) - 4.0), 1.0e-3
    assert row.jumps == 1
  end

  test "Compra por orden: orden de compra en Jita 4-4 y venta en Perimeter" do
    put_history()

    %{candidates: opps} =
      evaluate([
        {:buy, @tritanium, 4.0, 1_000_000, F.jita_44(), F.jita(), []},
        {:buy, @tritanium, 6.0, 2_000_000, F.perimeter_npc(), F.perimeter(), []}
      ])

    {[row], 1} = OrderQuery.run(opps, %{mode: :buy_order}, DateTime.utc_now())

    assert row.mode == :buy_order
    assert row.price == 4.01
    assert row.quantity == 1_400_000
    unit_cost = 4.01 * 1.018
    assert_in_delta row.profit, 1_400_000 * (6.0 * 0.958 - unit_cost), 1.0e-3
  end

  test "las órdenes propias no compiten: se supera a la siguiente" do
    put_history()

    %{candidates: opps} =
      evaluate([
        {:buy, @tritanium, 4.5, 1_000_000, F.jita_44(), F.jita(), []},
        {:buy, @tritanium, 4.0, 1_000_000, F.jita_44(), F.jita(), []},
        {:buy, @tritanium, 6.0, 2_000_000, F.perimeter_npc(), F.perimeter(), []}
      ])

    now = DateTime.utc_now()
    {[row], 1} = OrderQuery.run(opps, %{mode: :buy_order}, now)
    assert row.price == 4.51

    # La orden 1 (4,50) es del piloto: la propia orden no se supera a sí misma.
    {[row], 1} = OrderQuery.run(opps, %{mode: :buy_order, own_order_ids: MapSet.new([1])}, now)
    assert row.price == 4.01
  end

  test "sin historial en el hub no hay candidatos: se pide el historial" do
    result =
      evaluate([
        {:sell, @tritanium, 5.5, 1_000_000, F.jita_44(), F.jita(), []},
        {:sell, @tritanium, 4.0, 2_000_000, F.perimeter_npc(), F.perimeter(), []}
      ])

    assert result.candidates == []
    assert {10_000_002, @tritanium} in result.missing_history
  end

  test "las estructuras quedan fuera de la familia por órdenes (acceso, AS-8)" do
    put_history()

    %{candidates: opps} =
      evaluate([
        {:buy, @tritanium, 4.0, 1_000_000, F.jita_44(), F.jita(), []},
        {:buy, @tritanium, 6.0, 2_000_000, F.perimeter_station(), F.perimeter(), []}
      ])

    assert opps == []
  end

  test "Listado en una estructura con broker propio: publica ahí con esa comisión (RF-9.4)" do
    put_history()

    F.publish_orders([
      {:sell, @tritanium, 5.5, 1_000_000, F.perimeter_station(), F.perimeter(), []},
      {:sell, @tritanium, 4.0, 2_000_000, F.jita_44(), F.jita(), []}
    ])

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

    structure = %{
      location_id: F.perimeter_station(),
      system_id: F.perimeter(),
      region_id: 10_000_002,
      broker_override: 0.0
    }

    %{candidates: opps} = OrderEvaluator.run(sources, types, [structure])
    {[row], 1} = OrderQuery.run(opps, %{mode: :listing}, DateTime.utc_now())

    assert row.opportunity.destination.location_id == F.perimeter_station()
    assert row.opportunity.hub_broker_override == 0.0
    assert row.broker_rate == 0.0
    assert_in_delta row.profit, row.quantity * (5.49 * (1 - 0.042) - 4.0), 1.0e-3
  end

  test "la cota universal descarta lo que no llega al beneficio mínimo" do
    put_history()

    # Mismo diferencial pero el hub casi no opera: el tope del mercado deja poco beneficio.
    as_of = HistoryStats.last_day(DateTime.utc_now())

    thin =
      0..29
      |> Enum.map(
        &%{"date" => Date.to_iso8601(Date.add(as_of, -&1)), "average" => 5.0, "volume" => 10}
      )
      |> HistoryStats.compute(as_of)

    :ets.insert(:eth_history_stats, {{10_000_002, @tritanium}, thin})

    %{candidates: opps} =
      evaluate([
        {:sell, @tritanium, 5.5, 1_000_000, F.jita_44(), F.jita(), []},
        {:sell, @tritanium, 4.0, 2_000_000, F.perimeter_npc(), F.perimeter(), []}
      ])

    assert opps == []
  end
end
