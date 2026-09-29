defmodule Eth.Engine.OwnOrdersTest do
  use ExUnit.Case, async: true

  alias Eth.Characters.OrderWatch
  alias Eth.Engine.OwnOrders

  @issued ~U[2026-09-29 10:00:00Z]

  defp order(attrs) do
    Map.merge(
      %{order_id: 1, buy: false, price: 5.0, volume_remain: 1_000, issued: @issued},
      attrs
    )
  end

  # Entrada del libro: {precio, volumen, order_id, emitida_unix, min_volume}.
  defp entry(price, id, issued \\ @issued), do: {price / 1, 100, id, DateTime.to_unix(issued), 1}

  test "sin competencia la orden va primera" do
    assert %{status: :best, suggested_price: nil} =
             OwnOrders.evaluate(order(%{}), [], MapSet.new([1]), 0.02, 0)
  end

  test "una venta más barata ajena la supera: se sugiere el precio legal inferior" do
    book = [entry(4.9, 7), entry(5.0, 1)]
    result = OwnOrders.evaluate(order(%{}), book, MapSet.new([1]), 0.02, 5)

    assert result.status == :outbid
    assert result.best_competitor == 4.9
    assert result.suggested_price == 4.89
    # Bajar el precio: solo la parte con descuento (ABR V ⇒ 80 %).
    assert_in_delta result.relist_fee, 0.2 * 0.02 * 4.89 * 1_000, 1.0e-9
  end

  test "una compra más alta ajena la supera: se sugiere el precio legal superior" do
    book = [entry(4.2, 7), entry(4.0, 1)]
    result = OwnOrders.evaluate(order(%{buy: true, price: 4.0}), book, MapSet.new([1]), 0.02, 0)

    assert result.status == :outbid
    assert result.suggested_price == 4.21
  end

  test "a igual precio gana la más antigua" do
    older = DateTime.add(@issued, -3600, :second)
    newer = DateTime.add(@issued, 3600, :second)

    assert OwnOrders.evaluate(order(%{}), [entry(5.0, 7, older)], MapSet.new([1]), 0.02, 0).status ==
             :outbid

    assert OwnOrders.evaluate(order(%{}), [entry(5.0, 7, newer)], MapSet.new([1]), 0.02, 0).status ==
             :best
  end

  test "las otras órdenes propias no cuentan como competencia" do
    book = [entry(4.9, 2), entry(5.1, 7)]
    assert OwnOrders.evaluate(order(%{}), book, MapSet.new([1, 2]), 0.02, 0).status == :best
  end

  test "resumen: órdenes frente al límite, escrow y valor en venta" do
    orders = [
      order(%{order_id: 1, price: 5.0, volume_remain: 10}),
      order(%{order_id: 2, buy: true, price: 4.0, volume_remain: 10, escrow: 40.0})
    ]

    assert %{count: 2, limit: 25, escrow: 40.0, sell_value: 50.0} =
             OwnOrders.summary(orders, %{3_443 => 5})
  end

  test "solo avisa las órdenes que pasan de primera a superada" do
    previous = %{1 => :best, 2 => :outbid}

    rows = [
      %{order_id: 1, status: :outbid},
      %{order_id: 2, status: :outbid},
      %{order_id: 3, status: :outbid}
    ]

    assert [%{order_id: 1}] = OrderWatch.newly_outbid(previous, rows)
  end
end
