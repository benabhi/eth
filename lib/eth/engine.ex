defmodule Eth.Engine do
  @moduledoc """
  API pública del motor de evaluación para la web y otros contextos (RNF-7.3).

  Implementa: RF-4.8, RF-4.12, RF-4.13, RF-4.14, RF-6.5.
  """

  alias Eth.{Clock, Events, Repo}

  alias Eth.Engine.{
    Coordinator,
    Opportunity,
    Query,
    RouteRisk,
    SaleQuote,
    ScamReport,
    StationOpportunity,
    StationQuery,
    Summary
  }

  alias Eth.Market.TableOwner

  @doc "Tópico con los anuncios de nueva versión de oportunidades."
  @spec topic() :: String.t()
  defdelegate topic, to: Coordinator

  @doc "Metadatos de la evaluación vigente (versión, duración, conteos) o `nil`."
  @spec meta() :: map() | nil
  def meta do
    case Coordinator.current() do
      {_tid, meta} -> meta
      nil -> nil
    end
  end

  @doc "Oportunidades universales vigentes."
  @spec all() :: [Opportunity.t()]
  def all do
    case Coordinator.current() do
      {tid, _meta} -> tid |> :ets.tab2list() |> Enum.map(&elem(&1, 1))
      nil -> []
    end
  rescue
    ArgumentError -> []
  end

  @doc "Oportunidad universal por ID."
  @spec get(String.t()) :: Opportunity.t() | nil
  def get(id) do
    case Coordinator.current() do
      {tid, _meta} ->
        case :ets.lookup(tid, id) do
          [{^id, opp}] -> opp
          [] -> nil
        end

      nil ->
        nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc """
  Registra un falso positivo del anti-scam (RF-4.8) a partir de una fila personalizada,
  con un comentario opcional.
  """
  @spec report_false_positive(map(), String.t() | nil) ::
          {:ok, ScamReport.t()} | {:error, Ecto.Changeset.t()}
  def report_false_positive(row, reason \\ nil) do
    %ScamReport{}
    |> ScamReport.changeset(%{opportunity_snapshot: ScamReport.snapshot(row), reason: reason})
    |> Repo.insert()
    |> tap(fn
      {:ok, _report} ->
        Events.emit(
          :action,
          "Usuario",
          "Falso positivo reportado: #{row.opportunity.type_name} (#{row.shield.status})"
        )

      _error ->
        :ok
    end)
  end

  @doc """
  Detalle por sistema del camino de una fila personalizada (RF-6.5, sección Ruta): ida
  hasta el origen sin carga y viaje cargado hasta el destino.
  """
  @spec route_details(map(), atom()) :: %{to_origin: [map()], route: [map()]}
  def route_details(row, ship_class) do
    ctx = RouteRisk.context()

    %{
      to_origin: RouteRisk.details(row.to_origin_path, ship_class, 0, ctx),
      route: RouteRisk.details(row.route_path, ship_class, row.cost, ctx)
    }
  end

  @doc """
  Cotizaciones de venta de `quantity` unidades de un tipo con las órdenes de compra
  vigentes de todas las fuentes (RF-7.3), de mayor a menor ingreso neto.
  """
  @spec sale_quotes(pos_integer(), pos_integer(), float()) :: [SaleQuote.quote_result()]
  def sale_quotes(type_id, quantity, tax) do
    SaleQuote.best(bids(type_id), quantity, tax, &Eth.Routing.distance(&1, &2, :shortest))
  end

  @doc "Cotización de venta en una estación concreta (RF-7.3)."
  @spec sale_quote(pos_integer(), map(), pos_integer(), float()) :: SaleQuote.quote_result()
  def sale_quote(type_id, location, quantity, tax) do
    SaleQuote.at(location, bids(type_id), quantity, tax, &Eth.Routing.distance(&1, &2, :shortest))
  end

  # Órdenes de compra del tipo en todas las fuentes, sin las de estructuras que se leen
  # directo repetidas en la región (RF-1.6).
  defp bids(type_id) do
    entries = TableOwner.all()
    direct = for {{:structure, id}, _entry} <- entries, into: MapSet.new(), do: id

    for {source, entry} <- entries,
        region_id = region_of(source, entry),
        {price, loc, sys, range, vol, min_vol, _issued} <- elem(Summary.get(source, type_id), 1),
        not (match?({:region, _}, source) and MapSet.member?(direct, loc)) do
      %{
        price: price,
        location_id: loc,
        system_id: sys,
        region_id: region_id,
        range: range,
        volume: vol,
        min_volume: min_vol
      }
    end
  rescue
    ArgumentError -> []
  end

  defp region_of({:region, id}, _entry), do: id
  defp region_of({:structure, _id}, entry), do: entry.meta[:region_id]

  @doc "Consulta personalizada (RF-4.14): `{filas, total}`."
  @spec query(Query.params()) :: {[map()], non_neg_integer()}
  def query(params \\ %{}) do
    started = System.monotonic_time(:microsecond)
    result = Query.run(all(), params, Clock.utc_now())

    :telemetry.execute(
      [:eth, :engine, :query],
      %{duration_us: System.monotonic_time(:microsecond) - started},
      %{rows: elem(result, 1)}
    )

    result
  end

  ## Station trading (RF-4.16)

  @doc "Candidatos universales de station trading vigentes."
  @spec station_all() :: [StationOpportunity.t()]
  def station_all do
    case Coordinator.current_station() do
      nil -> []
      tid -> tid |> :ets.tab2list() |> Enum.map(&elem(&1, 2))
    end
  rescue
    ArgumentError -> []
  end

  @doc "Candidato de station trading por ID."
  @spec station_get(String.t()) :: StationOpportunity.t() | nil
  def station_get(id) do
    case Coordinator.current_station() do
      nil ->
        nil

      tid ->
        case :ets.lookup(tid, id) do
          [{^id, _pair, opp}] -> opp
          [] -> nil
        end
    end
  rescue
    ArgumentError -> nil
  end

  @doc """
  Consulta personalizada de station trading: `{filas, total}`. Primero descarta, sin
  copiar los candidatos, los que no tienen historial suficiente (la gran mayoría).
  """
  @spec station_query(StationQuery.params()) :: {[map()], non_neg_integer()}
  def station_query(params \\ %{}) do
    opportunities =
      case Coordinator.current_station() do
        nil -> []
        tid -> liquid_station_candidates(tid, StationQuery.liquid_pair_fun(params))
      end

    StationQuery.run(opportunities, params, Clock.utc_now())
  rescue
    ArgumentError -> {[], 0}
  end

  defp liquid_station_candidates(tid, liquid?) do
    tid
    |> :ets.select([{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.filter(fn {_id, pair} -> liquid?.(pair) end)
    |> Enum.flat_map(fn {id, _pair} ->
      case :ets.lookup(tid, id) do
        [{^id, _pair, opp}] -> [opp]
        [] -> []
      end
    end)
  end
end
