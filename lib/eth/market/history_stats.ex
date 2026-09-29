defmodule Eth.Market.HistoryStats do
  @moduledoc """
  Estadísticas derivadas del historial diario de un tipo en una región (RF-1.12, ERS §7.2).
  Funciones puras.

  ESI publica el día `D` después del downtime de `D + 1` y solo incluye los días con
  operaciones. Las ventanas de 7 y 30 días son **de calendario** y terminan en `as_of`,
  el último día ya publicado (`last_day/1`): un día sin operaciones cuenta como volumen 0.

  | Campo | Definición |
  |---|---|
  | `median_7d` / `median_30d` | Mediana de los promedios diarios de los días con operaciones |
  | `avg_7d` / `avg_30d` | Precio promedio ponderado por volumen (ISK operado / unidades) |
  | `stddev_30d` | Desvío estándar de los promedios diarios (30 días) |
  | `volume_avg_7d` / `volume_avg_30d` | Unidades por día (días sin operaciones = 0) |
  | `days_traded_30d` | Días con operaciones en 30 días |
  | `daily_avg` / `daily_volume` | Los 30 días, del más viejo a `as_of` (`nil`/0 sin operaciones), para el sparkline |

  Implementa: RF-1.12.
  """

  alias Eth.GameRules

  @type t :: %{
          as_of: Date.t(),
          median_7d: float() | nil,
          median_30d: float() | nil,
          avg_7d: float() | nil,
          avg_30d: float() | nil,
          stddev_30d: float() | nil,
          volume_avg_7d: float(),
          volume_avg_30d: float(),
          days_traded_30d: non_neg_integer(),
          daily_avg: [float() | nil],
          daily_volume: [non_neg_integer()]
        }

  @doc """
  Último día cuyo historial ESI ya publicó: ayer si ya terminó el downtime de hoy
  (`:downtime_window_utc`), anteayer si todavía no.
  """
  @spec last_day(DateTime.t()) :: Date.t()
  def last_day(%DateTime{} = now) do
    {_from, to} = GameRules.get(:downtime_window_utc)
    today = DateTime.to_date(now)

    if Time.compare(DateTime.to_time(now), to) == :lt,
      do: Date.add(today, -2),
      else: Date.add(today, -1)
  end

  @doc "¿Las estadísticas siguen vigentes? (hasta que ESI publique un día nuevo)."
  @spec fresh?(t(), DateTime.t()) :: boolean()
  def fresh?(%{as_of: as_of}, now), do: Date.compare(as_of, last_day(now)) != :lt

  @doc "Calcula las estadísticas a partir de los elementos de ESI (`date`, `average`, `volume`)."
  @spec compute([map()], Date.t()) :: t()
  def compute(entries, %Date{} = as_of) do
    by_date =
      for %{"date" => date, "average" => avg, "volume" => vol} <- entries,
          {:ok, day} = Date.from_iso8601(date),
          vol > 0,
          into: %{},
          do: {day, {avg / 1, vol}}

    days_30 = Enum.map(29..0//-1, &Date.add(as_of, -&1))
    days_7 = Enum.take(days_30, -7)
    traded_30 = days_30 |> Enum.map(&by_date[&1]) |> Enum.reject(&is_nil/1)
    traded_7 = days_7 |> Enum.map(&by_date[&1]) |> Enum.reject(&is_nil/1)

    %{
      as_of: as_of,
      median_7d: median(Enum.map(traded_7, &elem(&1, 0))),
      median_30d: median(Enum.map(traded_30, &elem(&1, 0))),
      avg_7d: weighted_avg(traded_7),
      avg_30d: weighted_avg(traded_30),
      stddev_30d: stddev(Enum.map(traded_30, &elem(&1, 0))),
      volume_avg_7d: total_volume(traded_7) / 7,
      volume_avg_30d: total_volume(traded_30) / 30,
      days_traded_30d: length(traded_30),
      daily_avg: Enum.map(days_30, &(by_date[&1] && elem(by_date[&1], 0))),
      daily_volume: Enum.map(days_30, &((by_date[&1] && elem(by_date[&1], 1)) || 0))
    }
  end

  @doc "Mediana (`nil` si la lista está vacía)."
  @spec median([number()]) :: float() | nil
  def median([]), do: nil

  def median(values) do
    sorted = Enum.sort(values)
    n = length(sorted)
    mid = div(n, 2)

    if rem(n, 2) == 1,
      do: Enum.at(sorted, mid) / 1,
      else: (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2
  end

  defp weighted_avg([]), do: nil

  defp weighted_avg(days) do
    isk = Enum.reduce(days, 0.0, fn {avg, vol}, acc -> acc + avg * vol end)
    isk / total_volume(days)
  end

  defp total_volume(days), do: Enum.reduce(days, 0, fn {_avg, vol}, acc -> acc + vol end)

  defp stddev([]), do: nil

  defp stddev(values) do
    mean = Enum.sum(values) / length(values)
    variance = Enum.reduce(values, 0.0, &(&2 + (&1 - mean) ** 2)) / length(values)
    :math.sqrt(variance)
  end
end
