defmodule Eth.Engine do
  @moduledoc """
  API pública del motor de evaluación para la web y otros contextos (RNF-7.3).

  Implementa: RF-4.8, RF-4.12, RF-4.13, RF-4.14, RF-6.5.
  """

  alias Eth.{Clock, Events, Repo}
  alias Eth.Engine.{Coordinator, Opportunity, Query, RouteRisk, ScamReport}

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
end
