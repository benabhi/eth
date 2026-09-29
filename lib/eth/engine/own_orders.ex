defmodule Eth.Engine.OwnOrders do
  @moduledoc """
  Estado de las órdenes propias frente al libro (RF-4.17). Funciones puras.

  Una orden está **primera** si ninguna orden ajena del mismo lado en su ubicación tiene
  mejor precio; a igual precio gana la más antigua (como en el juego). Si está
  **superada**, se sugiere el precio legal que vuelve a dejarla primera
  (`Eth.Engine.OrderRules.outbid/1` o `undercut/1`) y el costo de modificarla (relist).

  Las órdenes de compra se comparan en su estación (una orden con rango también compite
  con las de estaciones cercanas: simplificación documentada en el ERS).
  """

  alias Eth.Engine.OrderRules

  @type order :: %{
          required(:order_id) => pos_integer(),
          required(:buy) => boolean(),
          required(:price) => float(),
          required(:volume_remain) => non_neg_integer(),
          required(:issued) => DateTime.t() | nil,
          optional(atom()) => any()
        }

  @type status :: :best | :outbid

  @doc """
  Evalúa una orden contra las órdenes de su lado y ubicación (`[{precio, volumen,
  order_id, emitida_unix, min_volume}]`, del mejor al peor), sin contar las propias
  (`own_ids`). `broker` en proporción y el nivel de Advanced Broker Relations para el
  relist.
  """
  @spec evaluate(order(), list(), MapSet.t(), float(), 0..5) :: %{
          status: status(),
          best_competitor: float() | nil,
          suggested_price: float() | nil,
          relist_fee: float() | nil
        }
  def evaluate(order, book, own_ids, broker, advanced_broker_relations) do
    case Enum.find(book, &(not MapSet.member?(own_ids, elem(&1, 2)))) do
      nil ->
        %{status: :best, best_competitor: nil, suggested_price: nil, relist_fee: nil}

      {price, _vol, _id, issued, _min} ->
        if ahead?(order, price, issued) do
          %{status: :best, best_competitor: price, suggested_price: nil, relist_fee: nil}
        else
          suggested = suggest(order, price)

          fee =
            suggested &&
              OrderRules.relist_fee(
                broker,
                order.price * order.volume_remain,
                suggested * order.volume_remain,
                advanced_broker_relations
              )

          %{status: :outbid, best_competitor: price, suggested_price: suggested, relist_fee: fee}
        end
    end
  end

  @doc "Resumen: órdenes abiertas frente al límite, ISK en escrow y valor en venta."
  @spec summary([order()], %{optional(pos_integer()) => 0..5}) :: %{
          count: non_neg_integer(),
          limit: pos_integer(),
          escrow: float(),
          sell_value: float()
        }
  def summary(orders, skills) do
    %{
      count: length(orders),
      limit: OrderRules.order_limit(skills),
      escrow:
        orders |> Enum.filter(& &1.buy) |> Enum.map(&Map.get(&1, :escrow, 0.0)) |> Enum.sum(),
      sell_value:
        orders |> Enum.reject(& &1.buy) |> Enum.map(&(&1.price * &1.volume_remain)) |> Enum.sum()
    }
  end

  # ¿La orden propia va primera frente al mejor competidor? A igual precio (en centavos,
  # sin comparar floats) gana la más antigua.
  defp ahead?(order, price, issued_unix) do
    mine = round(order.price * 100)
    theirs = round(price * 100)

    cond do
      mine == theirs -> older?(order.issued, issued_unix)
      order.buy -> mine > theirs
      true -> mine < theirs
    end
  end

  defp older?(nil, _issued_unix), do: false
  defp older?(%DateTime{} = issued, issued_unix), do: DateTime.to_unix(issued) <= issued_unix

  defp suggest(%{buy: true}, price), do: OrderRules.outbid(price)
  defp suggest(_sell, price), do: OrderRules.undercut(price)
end
