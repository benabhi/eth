defmodule Eth.Tracking.DomainTest do
  use ExUnit.Case, async: true

  alias Eth.Engine.SaleQuote
  alias Eth.Tracking.{Reconcile, Stages}

  @origin 60_003_760
  @destination 60_008_494

  @plan %{
    "type_id" => 2_488,
    "quantity" => 600,
    "origin_location_id" => @origin,
    "destination_location_id" => @destination,
    "cost" => 640_000_000.0,
    "revenue" => 678_000_000.0,
    "profit" => 38_000_000.0,
    "tax_rate" => 0.03375,
    "avg_buy" => 1_066_666.67,
    "avg_sell" => 1_170_000.0
  }

  defp run(status, wallet_at_start \\ 1.0e9),
    do: %{status: status, plan: @plan, wallet_at_start: wallet_at_start}

  describe "etapas (RF-7.2)" do
    test "recorre el viaje completo con ubicación y saldo" do
      assert Stages.next(run("planned"), %{docked_at: 1, moved: false}) == "planned"
      assert Stages.next(run("planned"), %{moved: true}) == "to_origin"

      # Atracado en el origen, pero todavía no gastó.
      assert Stages.next(run("to_origin"), %{docked_at: @origin, wallet: 1.0e9}) == "to_origin"
      # Gastó el 90 % de la inversión estando en el origen.
      assert Stages.next(run("to_origin"), %{docked_at: @origin, wallet: 1.0e9 - 580_000_000}) ==
               "bought"

      assert Stages.next(run("bought"), %{docked_at: @origin}) == "bought"
      assert Stages.next(run("bought"), %{docked_at: nil}) == "in_transit"
      assert Stages.next(run("in_transit"), %{docked_at: 1}) == "in_transit"
      assert Stages.next(run("in_transit"), %{docked_at: @destination}) == "at_destination"

      after_buy = 1.0e9 - 640_000_000

      assert Stages.next(run("at_destination"), %{wallet: after_buy + 100_000}) ==
               "at_destination"

      assert Stages.next(run("at_destination"), %{wallet: after_buy + 620_000_000}) == "closed"
    end

    test "sin saldo conocido no infiere compra ni venta" do
      assert Stages.next(run("to_origin", nil), %{docked_at: @origin, wallet: 1.0}) == "to_origin"
      assert Stages.next(run("at_destination"), %{}) == "at_destination"
      assert Stages.next(run("closed"), %{moved: true}) == "closed"
    end

    test "confirmación manual" do
      assert Stages.confirm("to_origin", :bought) == {:ok, "bought"}
      assert Stages.confirm("in_transit", :sold) == {:ok, "closed"}
      assert Stages.confirm("closed", :sold) == :error
    end
  end

  describe "reconciliación (RF-7.5)" do
    defp t(is_buy, quantity, price, location),
      do: %{
        type_id: 2_488,
        is_buy: is_buy,
        quantity: quantity,
        unit_price: price,
        location_id: location
      }

    test "beneficio real, desvío y causas" do
      txs = [
        t(true, 400, 1_060_000.0, @origin),
        t(true, 200, 1_080_000.0, @origin),
        t(false, 600, 1_160_000.0, @destination),
        # Otro tipo: no cuenta.
        %{type_id: 34, is_buy: true, quantity: 1, unit_price: 5.0, location_id: @origin}
      ]

      r = Reconcile.run(@plan, txs)
      assert r.bought_quantity == 600 and r.sold_quantity == 600
      assert r.complete
      assert_in_delta r.cost, 424_000_000 + 216_000_000, 1.0e-3
      assert_in_delta r.profit, 696_000_000 * (1 - 0.03375) - 640_000_000, 1.0e-3
      assert_in_delta r.deviation, (r.profit - 38_000_000) / 38_000_000, 1.0e-9
      assert "Venta promedio más barata que la planificada" in r.causes
    end

    test "venta parcial y en otra estación" do
      r =
        Reconcile.run(@plan, [t(true, 600, 1_000_000.0, @origin), t(false, 500, 1_200_000.0, 1)])

      refute r.complete
      assert "Parte de la venta fue en otra estación" in r.causes
      assert "Quedan 100 unidades sin vender" in r.causes
    end

    test "sin transacciones" do
      r = Reconcile.run(@plan, [])
      assert r.profit == 0.0
      assert r.causes == ["No hay compras del tipo en la estación de origen"]
    end
  end

  describe "cotización de venta (RF-7.3)" do
    defp bid(price, volume, location, opts \\ []) do
      %{
        price: price,
        volume: volume,
        location_id: location,
        system_id: Keyword.get(opts, :system, location),
        region_id: 1,
        range: Keyword.get(opts, :range, :station),
        min_volume: Keyword.get(opts, :min_volume, 1)
      }
    end

    test "vende de mayor a menor precio y respeta el volumen mínimo" do
      bids = [bid(10.0, 50, 1), bid(12.0, 30, 1), bid(11.0, 100, 1, min_volume: 80)]

      q =
        SaleQuote.at(%{location_id: 1, system_id: 1, region_id: 1}, bids, 100, 0.0, fn _, _ ->
          0
        end)

      # 30 a 12 y 50 a 10 (a la de 11 le quedarían 70 < 80).
      assert q.quantity == 80
      assert q.gross == 30 * 12.0 + 50 * 10.0
    end

    test "elige la estación con mayor ingreso neto" do
      bids = [bid(10.0, 100, 1), bid(15.0, 100, 2)]
      [best | _] = SaleQuote.best(bids, 100, 0.05, fn _, _ -> 0 end)
      assert best.location_id == 2
      assert_in_delta best.net, 1_500 * 0.95, 1.0e-9
    end
  end
end
