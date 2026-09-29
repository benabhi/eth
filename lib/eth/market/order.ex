defmodule Eth.Market.Order do
  @moduledoc """
  Representación compacta de una orden de mercado en ETS (RF-1.5).

  Fila: `{key, location_id, system_id, volume_remain, min_volume, range, issued_unix, price, page}`
  con `key = {type_id, side, sort_price, order_id}`:

  - `side` es `:sell` o `:buy`;
  - `sort_price` es `price` en ventas y `-price` en compras, así un recorrido del
    `ordered_set` por el prefijo `{type_id, side}` devuelve el libro ya ordenado del mejor
    al peor precio (ventas de menor a mayor, compras de mayor a menor);
  - `page` es la página de ESI de origen (para reutilizar páginas con 304).
  """

  @type side :: :sell | :buy
  @type range :: :station | :solarsystem | :region | 1..40
  @type key :: {pos_integer(), side(), float(), pos_integer()}
  @type row ::
          {key(), pos_integer(), pos_integer(), non_neg_integer(), pos_integer(), range(),
           integer(), float(), pos_integer()}

  @doc "Convierte una orden de ESI (mapa JSON) en una fila de ETS."
  @spec to_row(map(), pos_integer()) :: row()
  def to_row(%{"is_buy_order" => buy?} = order, page) do
    price = order["price"] / 1
    side = if buy?, do: :buy, else: :sell
    sort_price = if buy?, do: -price, else: price

    {{order["type_id"], side, sort_price, order["order_id"]}, order["location_id"],
     order["system_id"], order["volume_remain"], order["min_volume"], parse_range(order["range"]),
     parse_issued(order["issued"]), price, page}
  end

  @doc "Página de ESI de la que proviene una fila."
  @spec page(row()) :: pos_integer()
  def page(row), do: elem(row, 8)

  @doc "Posición (1-based, para `:ets.select_delete/2`) del campo página en la fila."
  @spec page_position() :: pos_integer()
  def page_position, do: 9

  @doc "Interpreta el rango de ESI sin crear átomos a partir de datos externos (RNF-4.11)."
  @spec parse_range(String.t()) :: range()
  def parse_range("station"), do: :station
  def parse_range("solarsystem"), do: :solarsystem
  def parse_range("region"), do: :region
  def parse_range(jumps) when jumps in ~w(1 2 3 4 5 10 20 30 40), do: String.to_integer(jumps)

  defp parse_issued(issued) do
    {:ok, datetime, 0} = DateTime.from_iso8601(issued)
    DateTime.to_unix(datetime)
  end
end
