defmodule Eth.Engine.StationEvaluator do
  @moduledoc """
  Cruce universal del station trading (RF-4.16) en los lugares de `Eth.Engine.PublishLocations` (los hubs y las estructuras con broker
  propio, RF-9.4).

  Por estación, para cada tipo de su región (en paralelo por estación):

  1. **Screening** con los resúmenes: mejor venta de la estación y mejor compra ubicada en
     ella; pasa si el margen con las comisiones más bajas posibles llega a
     `:screen_margin` (`Eth.Engine.StationTrading.candidate?/3`).
  2. **Libro de la estación:** hasta `:book_depth` órdenes por lado, leídas de la tabla de
     órdenes (`ordered_set` por `{tipo, lado, precio}`: las primeras que coinciden son
     las mejores).

  El margen personal, la competencia y el plan se calculan en la consulta
  (`Eth.Engine.StationQuery`).

  Implementa: RF-4.16.
  """

  alias Eth.Engine.{Locations, PublishLocations, StationOpportunity, StationTrading, Summary}
  alias Eth.{GameRules, Sde}
  alias Eth.Market.OrderBook

  @doc """
  Evalúa las estaciones de station trading. `entries` son las fuentes de
  `Eth.Market.TableOwner.all/0`; `types` los tipos presentes por fuente.
  """
  @spec run([{term(), map()}], %{term() => [pos_integer()]}, [PublishLocations.location()]) ::
          [StationOpportunity.t()]
  def run(entries, types, locations \\ PublishLocations.list()) do
    entries = Map.new(entries)
    depth = GameRules.get(:station_trading).book_depth

    locations
    |> Enum.flat_map(fn place ->
      source = PublishLocations.source(place, &Map.has_key?(entries, &1))

      case Map.get(entries, source) do
        %{} = entry -> [{place, source, entry}]
        nil -> []
      end
    end)
    |> Task.async_stream(
      fn {place, source, entry} ->
        ctx = %{
          location_id: place.location_id,
          location: Locations.describe(place.location_id, place.system_id),
          broker_override: place.broker_override,
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
         true <- StationTrading.candidate?(best_bid, best_ask, ctx.broker_override),
         {:ok, bids, asks} <- books(ctx, type_id),
         %{} = type <- Sde.type(type_id) do
      [
        %StationOpportunity{
          id: StationOpportunity.id(ctx.location_id, type_id),
          type_id: type_id,
          type_name: type.name,
          unit_volume: type.packaged_volume,
          location: ctx.location,
          broker_override: ctx.broker_override,
          last_modified: ctx.last_modified,
          bids: bids,
          asks: asks
        }
      ]
    else
      _ -> []
    end
  end

  # Libros de compra y venta de la estación. La generación pudo borrarse tras el período
  # de gracia durante una evaluación larga: el candidato se descarta en vez de tirar abajo
  # toda la evaluación (la próxima ya lee la generación nueva).
  defp books(ctx, type_id) do
    {:ok, book(ctx, type_id, :buy), book(ctx, type_id, :sell)}
  rescue
    ArgumentError -> :gone
  end

  defp book(ctx, type_id, side),
    do: OrderBook.at_location(ctx.tid, type_id, side, ctx.location_id, ctx.depth)
end
