defmodule Eth.Tracking do
  @moduledoc """
  Viajes de trading (M7): iniciar desde una oportunidad, seguir sus etapas, revalidar,
  alertar amenazas, cerrar y reconciliar con la billetera. API pública para la web
  (RNF-7.3); cada viaje activo tiene un `Eth.Tracking.RunMonitor`.

  El registro del cazador (RF-7.7) se arma con `hunter_log/2` sobre los viajes
  reconciliados; al guardar un resultado que logra un hito nuevo se avisa con un toast
  discreto (`Eth.Notifications`).

  Implementa: RF-7.1, RF-7.2, RF-7.5, RF-7.6, RF-7.7.
  """

  import Ecto.Query

  alias Eth.Characters.Sessions
  alias Eth.{Clock, Events, Notifications, Repo}
  alias Eth.Tracking.{HunterLog, Run, RunMonitor, Stages, WalletTransaction}

  @doc "Tópico con los cambios de los viajes de un personaje (`{:run, run}`)."
  @spec topic(pos_integer()) :: String.t()
  def topic(character_id), do: "run:#{character_id}"

  @doc """
  Inicia un viaje desde una fila personalizada del Cazador (RF-7.1): congela el plan
  (un tipo, una compra y una venta), toma el saldo actual y arranca su monitor. Un viaje
  activo por personaje.
  """
  @spec start(pos_integer(), map(), map()) :: {:ok, Run.t()} | {:error, term()}
  def start(character_id, row, query) do
    now = Clock.utc_now() |> DateTime.truncate(:second)
    wallet = get_in(Sessions.context(character_id) || %{}, [:context, :wallet])

    attrs = %Run{
      character_id: character_id,
      status: "planned",
      plan: plan(row, query),
      predicted_profit: row.profit,
      wallet_at_start: wallet,
      stages: %{"planned" => DateTime.to_iso8601(now)},
      started_at: now
    }

    case Repo.insert(attrs) do
      {:ok, run} ->
        RunMonitor.start(run)

        Events.emit(
          :action,
          "Viajes",
          "Viaje iniciado: #{run.plan["type_name"]} ×#{run.plan["quantity"]}"
        )

        broadcast(run)
        {:ok, run}

      {:error, _changeset} ->
        {:error, :already_active}
    end
  rescue
    Ecto.ConstraintError -> {:error, :already_active}
  end

  # Plan congelado (claves de string: se guarda como jsonb).
  defp plan(row, query) do
    opp = row.opportunity

    %{
      "opportunity_id" => opp.id,
      # Sistema donde estaba el piloto al iniciar: salir de ahí es "hacia el origen".
      "start_system_id" => Map.get(query, :base_system_id),
      "type_id" => opp.type_id,
      "type_name" => opp.type_name,
      "quantity" => row.quantity,
      "cargo_m3" => row.cargo_m3,
      "origin_location_id" => opp.origin.location_id,
      "origin_system_id" => opp.origin.system_id,
      "origin_name" => opp.origin.name,
      "destination_location_id" => opp.destination.location_id,
      "destination_system_id" => opp.destination.system_id,
      "destination_region_id" => opp.destination.region_id,
      "destination_name" => opp.destination.name,
      "cost" => row.cost,
      "revenue" => row.revenue,
      "profit" => row.profit,
      "tax_rate" => row.tax_rate,
      "avg_buy" => row.avg_buy,
      "avg_sell" => row.avg_sell,
      "jumps" => row.total_jumps,
      "seconds" => row.seconds,
      "route_mode" => Atom.to_string(Map.get(query, :route_mode, :secure)),
      "ship_class" => Atom.to_string(Map.get(query, :ship_class, :industrial)),
      "tvs" => row.tvs,
      "certainty" => row.certainty
    }
  end

  @doc "Viaje en curso de un personaje (`nil` si no tiene)."
  @spec active(pos_integer()) :: Run.t() | nil
  def active(character_id) do
    Repo.one(
      from r in Run,
        where: r.character_id == ^character_id and r.status in ^Run.active_statuses(),
        limit: 1
    )
  end

  @doc "Viajes del personaje, más recientes primero (RF-7.6)."
  @spec history(pos_integer(), pos_integer()) :: [Run.t()]
  def history(character_id, limit \\ 50) do
    Repo.all(
      from r in Run,
        where: r.character_id == ^character_id,
        order_by: [desc: r.started_at],
        limit: ^limit
    )
  end

  @doc """
  Registro del cazador (RF-7.7) de uno o varios personajes: estadísticas por período,
  racha, rango e hitos, solo con viajes cerrados y reconciliados.
  """
  @spec hunter_log(pos_integer() | [pos_integer()], DateTime.t()) :: HunterLog.t()
  def hunter_log(character_ids, now \\ Clock.utc_now()) do
    character_ids |> List.wrap() |> reconciled_runs() |> HunterLog.build(now)
  end

  defp reconciled_runs(character_ids) do
    Repo.all(
      from r in Run,
        where:
          r.character_id in ^character_ids and r.status == "closed" and
            not is_nil(r.realized_profit)
    )
  end

  @doc "Viaje por ID."
  @spec get(pos_integer()) :: Run.t() | nil
  def get(id), do: Repo.get(Run, id)

  @doc "Viajes que necesitan monitor al arrancar: activos o cerrados sin reconciliar."
  @spec to_monitor() :: [Run.t()]
  def to_monitor do
    Repo.all(
      from r in Run,
        where: r.status in ^Run.active_statuses() or (r.status == "closed" and is_nil(r.result))
    )
  end

  @doc "Confirmación manual de compra o de venta (RF-7.2)."
  @spec confirm(Run.t(), :bought | :sold) :: {:ok, Run.t()} | {:error, :invalid}
  def confirm(%Run{} = run, action) do
    case Stages.confirm(run.status, action) do
      {:ok, status} -> {:ok, advance(run, status, "manual")}
      :error -> {:error, :invalid}
    end
  end

  @doc "Aborta un viaje en curso."
  @spec abort(Run.t(), String.t()) :: Run.t()
  def abort(%Run{} = run, reason \\ "cancelado por el piloto") do
    run = advance(run, "aborted", reason)
    RunMonitor.stop(run.id)
    run
  end

  @doc """
  Pasa el viaje a otra etapa: guarda el momento, cierra si corresponde, registra el evento
  y avisa a la web.
  """
  @spec advance(Run.t(), String.t(), String.t() | nil) :: Run.t()
  def advance(%Run{status: status} = run, status, _reason), do: run

  def advance(%Run{} = run, status, reason) do
    now = Clock.utc_now() |> DateTime.truncate(:second)
    closing? = status in ["closed", "aborted"]

    changes = [
      status: status,
      stages: Map.put(run.stages || %{}, status, DateTime.to_iso8601(now)),
      closed_at: if(closing?, do: now, else: run.closed_at),
      close_reason: if(closing?, do: reason, else: run.close_reason),
      updated_at: now
    ]

    {1, [run]} =
      Repo.update_all(from(r in Run, where: r.id == ^run.id, select: r), set: changes)

    Events.emit(:info, "Viajes", "#{run.plan["type_name"]}: #{status_label(status)}")
    broadcast(run)
    run
  end

  @doc "Guarda el resultado de la reconciliación (RF-7.5)."
  @spec put_result(Run.t(), map()) :: Run.t()
  def put_result(%Run{} = run, result) do
    result = Map.new(result, fn {k, v} -> {Atom.to_string(k), v} end)
    before = run.character_id |> reconciled_runs_of() |> HunterLog.milestones()

    {1, [run]} =
      Repo.update_all(from(r in Run, where: r.id == ^run.id, select: r),
        set: [
          result: result,
          realized_profit: result["profit"],
          updated_at: Clock.utc_now() |> DateTime.truncate(:second)
        ]
      )

    broadcast(run)
    notify_milestones(run, before)
    run
  end

  defp reconciled_runs_of(character_id), do: reconciled_runs([character_id])

  # Aviso discreto por cada hito nuevo (RF-7.7): nunca bloquea ni interrumpe.
  defp notify_milestones(%Run{} = run, before) do
    known = HunterLog.achieved_keys(before)

    run.character_id
    |> reconciled_runs_of()
    |> HunterLog.milestones()
    |> Enum.filter(&(&1.achieved_at && not MapSet.member?(known, &1.key)))
    |> Enum.each(fn milestone ->
      Events.emit(:info, "Viajes", "Hito logrado: #{milestone_title(milestone)}")

      Notifications.notify(%{
        key: "milestone:#{run.character_id}:#{milestone.key}",
        level: :info,
        title: "Hito logrado",
        body: milestone_title(milestone),
        url: "/run"
      })
    end)
  end

  @doc "Título de un hito del registro del cazador, en español."
  @spec milestone_title(HunterLog.milestone()) :: String.t()
  def milestone_title(%{kind: :first}), do: "Primer contrato completado"

  def milestone_title(%{kind: :reward, target: target}),
    do: "Recompensa acumulada de #{short_isk(target)}"

  def milestone_title(%{kind: :s_contracts, target: 1}), do: "Primer contrato de rango S"
  def milestone_title(%{kind: :s_contracts, target: n}), do: "#{n} contratos de rango S"
  def milestone_title(%{kind: :streak, target: n}), do: "Racha de #{n} días con contratos"

  def milestone_title(%{kind: :accuracy, target: min}),
    do: "Precisión sostenida ≥ #{round(min * 100)} %"

  defp short_isk(v) when v >= 1_000_000_000, do: "#{div(round(v), 1_000_000_000)}B"
  defp short_isk(v), do: "#{div(round(v), 1_000_000)}M"

  @doc "Guarda transacciones de ESI (idempotente por `transaction_id`)."
  @spec store_transactions(pos_integer(), [map()]) :: :ok
  def store_transactions(character_id, body) do
    rows = Enum.map(body, &WalletTransaction.row(character_id, &1))

    Repo.insert_all(WalletTransaction, rows,
      on_conflict: :nothing,
      conflict_target: :transaction_id
    )

    :ok
  end

  @doc "Transacciones del personaje entre dos instantes."
  @spec transactions(pos_integer(), DateTime.t(), DateTime.t()) :: [WalletTransaction.t()]
  def transactions(character_id, from, to) do
    Repo.all(
      from t in WalletTransaction,
        where: t.character_id == ^character_id and t.date >= ^from and t.date <= ^to,
        order_by: t.date
    )
  end

  @doc "Etiqueta legible de una etapa."
  @spec status_label(String.t()) :: String.t()
  def status_label("planned"), do: "planificado"
  def status_label("to_origin"), do: "hacia el origen"
  def status_label("bought"), do: "comprado"
  def status_label("in_transit"), do: "en tránsito"
  def status_label("at_destination"), do: "en destino"
  def status_label("closed"), do: "cerrado"
  def status_label("aborted"), do: "abortado"

  @doc "Anuncia un cambio del viaje (web y notificaciones)."
  @spec broadcast(Run.t(), term()) :: :ok
  def broadcast(%Run{} = run, extra \\ nil) do
    Phoenix.PubSub.broadcast(Eth.PubSub, topic(run.character_id), {:run, run, extra})
  end
end
