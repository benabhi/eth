defmodule Eth.Engine.BookDepth do
  @moduledoc """
  Profundidad del libro más allá de lo que consume el contrato (RF-6.16). Funciones puras.

  - `next_levels/3`: las órdenes que siguen a las consumidas, del mejor al peor precio (la
    primera puede ser el resto de una orden consumida a medias).
  - `without_best_bid/4`: el contrato si la mejor orden de compra desaparece antes de
    llegar (otro piloto le vendió primero o el comprador la canceló), con el mismo
    walk-the-book del motor (`Eth.Engine.Book`).

  Implementa: RF-6.16.
  """

  alias Eth.Engine.Book

  @typedoc "Escalón del libro: `{precio, cantidad}`."
  @type level :: {float(), pos_integer()}

  @doc """
  Hasta `n` órdenes de `book` (del mejor al peor precio) después de saltear `consumed`
  unidades.
  """
  @spec next_levels([level()], non_neg_integer(), pos_integer()) :: [level()]
  def next_levels(book, consumed, n) do
    book
    |> Enum.reduce({consumed, []}, fn {price, qty}, {skip, acc} ->
      if skip >= qty, do: {skip - qty, acc}, else: {0, [{price, qty - skip} | acc]}
    end)
    |> elem(1)
    |> Enum.reverse()
    |> Enum.take(n)
  end

  @doc """
  Resultado del walk-the-book sin la orden de compra de mayor precio. `asks` y `bids` como
  en `Eth.Engine.Book.walk/4`; `limits` igual que en la consulta del piloto. Devuelve
  `nil` si sin esa orden el contrato no deja margen.
  """
  @spec without_best_bid([Book.ask()], [Book.bid()], float(), Book.limits()) ::
          Book.result() | nil
  def without_best_bid(_asks, [], _tax, _limits), do: nil

  def without_best_bid(asks, bids, tax, limits) do
    [_best | rest] = Enum.sort_by(bids, &elem(&1, 0), :desc)

    case Book.walk(asks, rest, tax, limits) do
      %{quantity: q} = result when q > 0 -> result
      _ -> nil
    end
  end
end
