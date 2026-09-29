defmodule Eth.Engine.Summary do
  @moduledoc """
  Resúmenes por tipo de cada fuente de órdenes, base del screening (RF-1.5, RF-4.2).

  Por cada `{fuente, tipo}` guarda:

  - `asks`: mejor precio de venta por ubicación `[{price, location_id, system_id}]`
    (ascendente);
  - `bids`: todas las órdenes de compra
    `[{price, location_id, system_id, range, volume, min_volume, issued_unix}]`
    (descendente).

  Se construye con una sola pasada por la tabla de órdenes y se guarda en una tabla ETS
  `ordered_set` con clave `{fuente, tipo}`: reemplazar una fuente borra solo su prefijo.
  Solo se recalcula cuando la fuente publica una generación nueva.

  Implementa: RF-1.5, RF-4.2.
  """

  @table :eth_engine_summaries

  @doc "Crea la tabla de resúmenes (la llama el dueño, `Eth.Engine.Coordinator`)."
  @spec create_table() :: :ets.table()
  def create_table do
    :ets.new(@table, [:named_table, :public, :ordered_set, read_concurrency: true])
  end

  @doc """
  Reemplaza el resumen de una fuente con el de la tabla de órdenes `tid`.
  Devuelve la lista de tipos presentes.
  """
  @spec replace(term(), :ets.tid()) :: [pos_integer()]
  def replace(source, tid) do
    per_type = :ets.foldl(&accumulate/2, %{}, tid)
    :ets.select_delete(@table, [{{{source, :_}, :_, :_}, [], [true]}])

    rows =
      for {type_id, {asks_by_loc, bids}} <- per_type do
        asks =
          asks_by_loc
          |> Enum.map(fn {loc, {price, sys}} -> {price, loc, sys} end)
          |> Enum.sort()

        {{source, type_id}, asks, Enum.sort_by(bids, &elem(&1, 0), :desc)}
      end

    :ets.insert(@table, rows)
    Map.keys(per_type)
  end

  @doc "Borra el resumen de una fuente."
  @spec delete(term()) :: :ok
  def delete(source) do
    :ets.select_delete(@table, [{{{source, :_}, :_, :_}, [], [true]}])
    :ok
  end

  @doc "Resumen de un tipo en una fuente (`{asks, bids}`; listas vacías si no hay)."
  @spec get(term(), pos_integer()) :: {list(), list()}
  def get(source, type_id) do
    case :ets.lookup(@table, {source, type_id}) do
      [{_, asks, bids}] -> {asks, bids}
      [] -> {[], []}
    end
  end

  # Fila de orden: {{type, side, sort_price, order_id}, loc, sys, vol, min_vol, range, issued, price, page}
  defp accumulate({{type, :sell, _, _}, loc, sys, _vol, _min, _range, _issued, price, _page}, acc) do
    Map.update(acc, type, {%{loc => {price, sys}}, []}, fn {asks, bids} ->
      {Map.update(asks, loc, {price, sys}, &min(&1, {price, sys})), bids}
    end)
  end

  defp accumulate({{type, :buy, _, _}, loc, sys, vol, min_vol, range, issued, price, _page}, acc) do
    bid = {price, loc, sys, range, vol, min_vol, issued}
    Map.update(acc, type, {%{}, [bid]}, fn {asks, bids} -> {asks, [bid | bids]} end)
  end
end
