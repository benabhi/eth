defmodule Eth.Engine.BookDepthTest do
  use ExUnit.Case, async: true

  alias Eth.Engine.BookDepth

  test "las órdenes que siguen a las consumidas, con el resto de la última a medias" do
    book = [{10.0, 100}, {9.8, 50}, {9.5, 200}, {9.0, 10}]

    assert BookDepth.next_levels(book, 120, 5) == [{9.8, 30}, {9.5, 200}, {9.0, 10}]
    assert BookDepth.next_levels(book, 0, 2) == [{10.0, 100}, {9.8, 50}]
    assert BookDepth.next_levels(book, 1_000, 5) == []
    assert BookDepth.next_levels([], 0, 5) == []
  end

  test "sin la mejor compra el contrato sigue con las siguientes o deja de rendir" do
    asks = [{5.0, 100}]

    # La siguiente compra todavía deja margen: se vende ahí.
    assert %{quantity: 100, avg_sell: 9.0} =
             BookDepth.without_best_bid(asks, [{10.0, 100, 1}, {9.0, 100, 1}], 0.0, %{})

    # Sin otra compra con margen: deja de ser rentable.
    assert BookDepth.without_best_bid(asks, [{10.0, 100, 1}, {4.0, 100, 1}], 0.0, %{}) == nil
    assert BookDepth.without_best_bid(asks, [{10.0, 100, 1}], 0.0, %{}) == nil
    assert BookDepth.without_best_bid(asks, [], 0.0, %{}) == nil
  end
end
