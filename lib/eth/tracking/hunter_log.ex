defmodule Eth.Tracking.HunterLog do
  @moduledoc """
  Registro del cazador (RF-7.7): perfil de caza del piloto a partir de sus viajes cerrados
  y reconciliados con la billetera (RF-7.5). Funciones puras: reciben los viajes y el
  instante, y devuelven estadísticas, racha, rango e hitos.

  Solo cuenta datos reales: un viaje entra cuando tiene `realized_profit` (el P&L que
  sale de las transacciones de ESI). No hay puntos ni recompensas inventadas.

  - **Estadísticas** por período (semana, mes e histórico): contratos, recompensa total,
    ISK/h promedio (recompensa sobre horas de viaje), precisión (1 − desvío medio entre
    lo proyectado y lo real) y mejor contrato.
  - **Racha:** días seguidos (UTC) con al menos un contrato cerrado, que terminan hoy o
    ayer.
  - **Rango del cazador:** según la recompensa acumulada (`Eth.Engine.Grade`).
  - **Hitos** calibrables (`:hunter_milestones`): primer contrato, recompensa
    acumulada, contratos de rango S, racha y precisión sostenida; cada uno con el
    momento y el viaje con que se logró.

  Implementa: RF-7.7.
  """

  alias Eth.Engine.Grade
  alias Eth.GameRules

  @type run :: %{
          required(:id) => term(),
          required(:realized_profit) => number() | nil,
          required(:predicted_profit) => number() | nil,
          required(:started_at) => DateTime.t(),
          required(:closed_at) => DateTime.t() | nil,
          required(:plan) => map(),
          optional(atom()) => term()
        }

  @type stats :: %{
          contracts: non_neg_integer(),
          reward: float(),
          isk_per_hour: float() | nil,
          accuracy: float() | nil,
          best: run() | nil
        }

  @type milestone :: %{
          key: String.t(),
          kind: :first | :reward | :s_contracts | :streak | :accuracy,
          target: number(),
          achieved_at: DateTime.t() | nil,
          run: run() | nil,
          progress: float()
        }

  @type t :: %{
          week: stats(),
          month: stats(),
          all: stats(),
          streak: non_neg_integer(),
          rank: Grade.hunter_rank(),
          milestones: [milestone()]
        }

  @doc "Registro completo a partir de los viajes (en cualquier orden) y el instante."
  @spec build([run()], DateTime.t()) :: t()
  def build(runs, now) do
    runs = reconciled(runs)
    all = stats(runs)

    %{
      week: stats(since(runs, now, 7)),
      month: stats(since(runs, now, 30)),
      all: all,
      streak: streak(runs, now),
      rank: Grade.hunter_rank(all.reward),
      milestones: milestones(runs)
    }
  end

  @doc "Viajes que cuentan: cerrados y con P&L real, del más viejo al más nuevo."
  @spec reconciled([run()]) :: [run()]
  def reconciled(runs) do
    runs
    |> Enum.filter(&(is_number(&1.realized_profit) and not is_nil(&1.closed_at)))
    |> Enum.sort_by(& &1.closed_at, DateTime)
  end

  @doc "Estadísticas de un conjunto de viajes reconciliados."
  @spec stats([run()]) :: stats()
  def stats([]), do: %{contracts: 0, reward: 0.0, isk_per_hour: nil, accuracy: nil, best: nil}

  def stats(runs) do
    reward = runs |> Enum.map(& &1.realized_profit) |> Enum.sum() |> Kernel.*(1.0)
    hours = runs |> Enum.map(&hours/1) |> Enum.sum()
    accuracies = runs |> Enum.map(&accuracy/1) |> Enum.reject(&is_nil/1)

    %{
      contracts: length(runs),
      reward: reward,
      isk_per_hour: if(hours > 0, do: reward / hours),
      accuracy: if(accuracies != [], do: Enum.sum(accuracies) / length(accuracies)),
      best: Enum.max_by(runs, & &1.realized_profit)
    }
  end

  @doc """
  Precisión de un viaje: 1 − |real − proyectado| / |proyectado|, entre 0 y 1. `nil` sin
  proyección.
  """
  @spec accuracy(run()) :: float() | nil
  def accuracy(%{predicted_profit: predicted, realized_profit: real})
      when is_number(predicted) and predicted != 0 and is_number(real) do
    max(1.0 - abs(real - predicted) / abs(predicted), 0.0)
  end

  def accuracy(_run), do: nil

  @doc "Días seguidos con contratos cerrados que terminan hoy o ayer (UTC)."
  @spec streak([run()], DateTime.t()) :: non_neg_integer()
  def streak(runs, now) do
    days = runs |> Enum.map(&DateTime.to_date(&1.closed_at)) |> MapSet.new()
    today = DateTime.to_date(now)

    start =
      cond do
        MapSet.member?(days, today) -> today
        MapSet.member?(days, Date.add(today, -1)) -> Date.add(today, -1)
        true -> nil
      end

    if start, do: count_back(days, start, 0), else: 0
  end

  defp count_back(days, day, acc) do
    if MapSet.member?(days, day), do: count_back(days, Date.add(day, -1), acc + 1), else: acc
  end

  @doc """
  Hitos en orden: los logrados con su momento y viaje, los pendientes con su progreso
  (0–1). Se recorren los viajes en orden y cada umbral se marca en el viaje que lo cruza.
  """
  @spec milestones([run()]) :: [milestone()]
  def milestones(runs) do
    config = GameRules.get(:hunter_milestones)
    runs = reconciled(runs)
    series = series(runs, config.accuracy.window)

    [milestone("first", :first, 1, series, & &1.contracts)] ++
      Enum.map(
        config.reward,
        &milestone("reward:#{&1}", :reward, &1, series, fn s -> s.reward end)
      ) ++
      Enum.map(
        config.s_contracts,
        &milestone("s:#{&1}", :s_contracts, &1, series, fn s -> s.s_contracts end)
      ) ++
      Enum.map(
        config.streak_days,
        &milestone("streak:#{&1}", :streak, &1, series, fn s -> s.best_streak end)
      ) ++
      [
        milestone(
          "accuracy:#{config.accuracy.min}",
          :accuracy,
          config.accuracy.min,
          series,
          & &1.rolling_accuracy
        )
      ]
  end

  # Estado acumulado después de cada viaje: {viaje, acumulados}.
  defp series(runs, window) do
    {series, _acc} =
      Enum.map_reduce(runs, %{contracts: 0, reward: 0.0, s: 0, days: [], recent: []}, fn run,
                                                                                         acc ->
        day = DateTime.to_date(run.closed_at)
        days = if day in acc.days, do: acc.days, else: [day | acc.days]
        recent = Enum.take([accuracy(run) | acc.recent], window)

        acc = %{
          contracts: acc.contracts + 1,
          reward: acc.reward + run.realized_profit,
          s: acc.s + if(s_rank?(run), do: 1, else: 0),
          days: days,
          recent: recent
        }

        point = %{
          contracts: acc.contracts,
          reward: acc.reward,
          s_contracts: acc.s,
          best_streak: best_streak(days),
          rolling_accuracy: rolling(recent, window)
        }

        {{run, point}, acc}
      end)

    series
  end

  defp s_rank?(%{plan: %{"tvs" => tvs}}) when is_number(tvs), do: Grade.rank(tvs) == "S"
  defp s_rank?(_run), do: false

  # Precisión media de los últimos `window` viajes, solo si ya hay `window` con proyección.
  defp rolling(recent, window) do
    values = Enum.reject(recent, &is_nil/1)
    if length(values) >= window, do: Enum.sum(values) / length(values), else: 0.0
  end

  # Racha más larga de días seguidos entre los días con cierres.
  defp best_streak(days) do
    {best, _current, _prev} =
      days
      |> Enum.sort(Date)
      |> Enum.reduce({0, 0, nil}, fn day, {best, current, prev} ->
        current = if prev && Date.diff(day, prev) == 1, do: current + 1, else: 1
        {max(best, current), current, day}
      end)

    best
  end

  defp milestone(key, kind, target, series, value) do
    case Enum.find(series, fn {_run, point} -> value.(point) >= target end) do
      {run, _point} ->
        %{
          key: key,
          kind: kind,
          target: target,
          achieved_at: run.closed_at,
          run: run,
          progress: 1.0
        }

      nil ->
        current =
          case List.last(series) do
            {_run, point} -> value.(point)
            nil -> 0
          end

        %{
          key: key,
          kind: kind,
          target: target,
          achieved_at: nil,
          run: nil,
          progress: min(current / target, 1.0) * 1.0
        }
    end
  end

  @doc "Claves de los hitos logrados (para avisar solo los nuevos)."
  @spec achieved_keys([milestone()]) :: MapSet.t(String.t())
  def achieved_keys(milestones),
    do: for(%{achieved_at: %DateTime{}, key: key} <- milestones, into: MapSet.new(), do: key)

  defp hours(%{started_at: %DateTime{} = s, closed_at: %DateTime{} = c}),
    do: max(DateTime.diff(c, s), 60) / 3600

  defp since(runs, now, days) do
    from = DateTime.add(now, -days * 86_400, :second)
    Enum.filter(runs, &(DateTime.compare(&1.closed_at, from) != :lt))
  end
end
