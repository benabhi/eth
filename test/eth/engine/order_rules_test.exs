defmodule Eth.Engine.OrderRulesTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Eth.Engine.OrderRules

  describe "precios legales (4 cifras significativas)" do
    test "ejemplos del blog de CCP" do
      for price <- [1_112_000, 1_111_000, 1_110_000, 1_109_000, 999_900, 999_800, 999_700],
          do: assert(OrderRules.legal?(price))

      refute OrderRules.legal?(11_999_000)
      refute OrderRules.legal?(1_905_944_000)
      assert OrderRules.legal?(12.34)
      refute OrderRules.legal?(12.345)
      refute OrderRules.legal?(1_234.5)
      refute OrderRules.legal?(0)
    end

    test "superar una compra y una venta" do
      assert OrderRules.outbid(1_109_000) == 1_110_000.0
      assert OrderRules.outbid(999_900) == 1_000_000.0
      assert OrderRules.outbid(4.99) == 5.0
      assert OrderRules.outbid(12.34) == 12.35
      # Orden vieja con más cifras: el siguiente precio legal por encima.
      assert OrderRules.outbid(1_234.56) == 1_235.0

      assert OrderRules.undercut(1_110_000) == 1_109_000.0
      assert OrderRules.undercut(1_000_000) == 999_900.0
      assert OrderRules.undercut(10_000) == 9_999.0
      assert OrderRules.undercut(1_234.56) == 1_234.0
      assert OrderRules.undercut(0.01) == nil
    end

    property "outbid da un precio legal y mayor; undercut, uno legal y menor" do
      check all(cents <- StreamData.integer(1..10_000_000_000)) do
        price = cents / 100
        up = OrderRules.outbid(price)
        assert OrderRules.legal?(up)
        assert up > price

        case OrderRules.undercut(price) do
          nil ->
            assert cents == 1

          down ->
            assert OrderRules.legal?(down)
            assert down < price
        end
      end
    end

    property "no hay precio legal entre el precio y su outbid" do
      check all(cents <- StreamData.integer(1..100_000_000)) do
        price = OrderRules.round_down(cents / 100)
        up = OrderRules.outbid(price)
        assert OrderRules.undercut(up) == price
      end
    end
  end

  test "relist con Advanced Broker Relations" do
    # Bajar el precio: solo la parte con descuento. ABR 0 ⇒ RD 50 %; ABR 5 ⇒ RD 80 %.
    assert_in_delta OrderRules.relist_fee(0.02, 1_000_000, 900_000, 0), 9_000.0, 1.0e-6
    assert_in_delta OrderRules.relist_fee(0.02, 1_000_000, 900_000, 5), 3_600.0, 1.0e-6

    # Subir el precio: broker completo sobre el aumento más la parte con descuento.
    assert_in_delta OrderRules.relist_fee(0.02, 1_000_000, 1_100_000, 5),
                    0.02 * 100_000 + 0.2 * 0.02 * 1_100_000,
                    1.0e-6
  end

  test "límite de órdenes por habilidades" do
    assert OrderRules.order_limit(%{}) == 5
    assert OrderRules.order_limit(%{3_443 => 5, 3_444 => 5, 16_596 => 5, 18_580 => 5}) == 305
    assert OrderRules.order_limit(%{3_443 => 4, 3_444 => 1}) == 5 + 16 + 8
  end

  test "escrow completo sin Margin Trading" do
    assert OrderRules.escrow(1_000_000) == 1_000_000.0
  end
end
