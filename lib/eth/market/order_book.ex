defmodule Eth.Market.OrderBook do
  @moduledoc """
  Lectura del libro de una ubicación desde una tabla de órdenes (RF-1.5).

  Las tablas son `ordered_set` con clave `{tipo, lado, precio_orden, order_id}` (ver
  `Eth.Market.Order`): un recorrido por el prefijo `{tipo, lado}` devuelve el libro del
  mejor al peor precio, así que las primeras filas que coinciden con la ubicación son
  las mejores. Lo usan el station trading (RF-4.16) y el seguimiento de órdenes propias
  (RF-4.17).
  """

  @typedoc "Orden: `{precio, volumen restante, order_id, emitida (unix), min_volume}`."
  @type entry :: {float(), non_neg_integer(), pos_integer(), integer(), pos_integer()}

  @doc "Hasta `limit` órdenes de un lado en una ubicación, del mejor al peor precio."
  @spec at_location(:ets.tid(), pos_integer(), :buy | :sell, pos_integer(), pos_integer()) ::
          [entry()]
  def at_location(tid, type_id, side, location_id, limit) do
    spec = [
      {{{type_id, side, :_, :"$1"}, location_id, :_, :"$2", :"$3", :_, :"$4", :"$5", :_}, [],
       [{{:"$5", :"$2", :"$1", :"$4", :"$3"}}]}
    ]

    case :ets.select(tid, spec, limit) do
      {rows, _continuation} -> rows
      :"$end_of_table" -> []
    end
  end
end
