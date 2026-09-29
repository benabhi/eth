defmodule Eth.Engine.StationEvaluator do
  @moduledoc """
  Cruce universal del station trading (RF-4.16) en las estaciones de
  `:station_trading_location_ids` (los hubs).

  Por estación, para cada tipo de su región (en paralelo por estación):

  1. **Screening** con los resúmenes: mejor venta de la estación y mejor compra ubicada en
     ella; pasa si el margen con las comisiones más bajas posibles llega a
     `:screen_margin` (`Eth.Engine.StationTrading.candidate?/2`).
  2. **Libro de la estación:** hasta `:book_depth` órdenes por lado, leídas de la tabla de
     órdenes (`ordered_set` por `{tipo, lado, precio}`: las primeras que coinciden son
     las mejores).

  El margen personal, la competencia y el plan se calculan en la consulta
  (`Eth.Engine.StationQuery`).

  Implementa: RF-4.16.
  """

  alias Eth.Engine.{Locations, StationOpportunity, StationTrading, Summary}
  alias Eth.{GameRules, Sde}
  alias Eth.Market.OrderBook

  @doc """
  Evalúa las estaciones de station trading. `entries` son las fuentes de
  `Eth.Market.TableOwner.all/0`; `types` los tipos presentes por fuente.
  """
  @spec run([{term(), map()}], %{term() => [pos_integer()]}) :: [StationOpportunity.t()]
  def run(entries, types) do
    entries = Map.new(entries)
    depth = GameRules.get(:station_trading).book_depth

    :station_trading_location_ids
    |> GameRules.get()
    |> Enum.flat_map(fn location_id ->
      with %{} = station <- Sde.station(location_id),
           source = {:region, station.region_id},
           %{} = entry <- Map.get(entries, source) do
        [{location_id, station, source, entry}]
      else
        _ -> []
      end
    end)
    |> Task.async_stream(
      fn {location_id, station, source, entry} ->
        ctx = %{
          location_id: location_id,
          location: Locations.describe(location_id, station.system_id),
          source: source,
          tid: entry.tid,
          last_modified: entry.meta.last_modified,
          depth: depth
        }

        types |> Map.get(source, []) |> Enum.flat_map(&evaluate_type(&1, ctx))
      end,
      ordered: false,
      timeout: :infinity
    )
    |> Enum.flat_map(fn {:ok, opportunities} -> opportunities end)
  end

  @doc false
  @spec evaluate_type(pos_integer(), map()) :: [StationOpportunity.t()]
  def evaluate_type(type_id, ctx) do
    {asks, bids} = Summary.get(ctx.source, type_id)

    with {best_ask, _loc, _sys} <- Enum.find(asks, &(elem(&1, 1) == ctx.location_id)),
         {best_bid, _loc, _sys, _r, _v, _m, _i} <-
           Enum.find(bids, &(elem(&1, 1) == ctx.location_id)),
         true <- StationTrading.candidate?(best_bid, best_ask),
         %{} = type <- Sde.type(type_id) do
      [
        %StationOpportunity{
          id: StationOpportunity.id(ctx.location_id, type_id),
          type_id: type_id,
          type_name: type.name,
          unit_volume: type.packaged_volume,
          location: ctx.location,
          last_modified: ctx.last_modified,
          bids: book(ctx, type_id, :buy),
          asks: book(ctx, type_id, :sell)
        }
      ]
    else
      _ -> []
    end
  end

  defp book(ctx, type_id, side),
    do: OrderBook.at_location(ctx.tid, type_id, side, ctx.location_id, ctx.depth)
end
