defmodule Eth.Engine.Score do
  @moduledoc """
  Tiempo de viaje, ISK/h, utilidad, Certeza y TVS (RF-2.7, RF-4.12, ERS §8.9–§8.10).
  Funciones puras; pesos y referencias en `Eth.GameRules`.

  En F3 la Certeza combina vigencia de las órdenes al llegar y frescura de los datos;
  anti-scam (F5), acceso a estructuras (F7) y riesgo de ruta (F6) se suman después.

  Implementa: RF-2.7, RF-4.9, RF-4.12.
  """

  alias Eth.GameRules

  @doc """
  Segundos de viaje: `saltos × t_salto(clase) + paradas × t_parada` (ERS §8.10).
  """
  @spec travel_seconds(non_neg_integer(), non_neg_integer(), atom()) :: non_neg_integer()
  def travel_seconds(jumps, stops, ship_class) do
    per_jump = GameRules.get(:jump_seconds)

    jumps * Map.get(per_jump, ship_class, per_jump.other) +
      stops * GameRules.get(:stop_overhead_s)
  end

  @doc "ISK por hora (0 si el tiempo es 0)."
  @spec isk_per_hour(number(), non_neg_integer()) :: float()
  def isk_per_hour(_profit, 0), do: 0.0
  def isk_per_hour(profit, seconds), do: profit * 3600 / seconds

  @doc "Normalización cóncava: 0 → 0, ref → 1, acotada en 1 (`log10(1 + 9x/ref)`)."
  @spec norm(number(), number()) :: float()
  def norm(x, _ref) when x <= 0, do: 0.0
  def norm(x, ref), do: min(1.0, :math.log10(1 + 9 * x / ref))

  @doc "Utilidad 0–1: ISK/h, beneficio, ROI y liquidez ponderados."
  @spec utility(%{isk_per_hour: number(), profit: number(), roi: number(), liquidity: number()}) ::
          float()
  def utility(m) do
    w = GameRules.get(:tvs_weights)
    r = GameRules.get(:tvs_refs)

    w.isk_per_hour * norm(m.isk_per_hour, r.isk_per_hour) + w.profit * norm(m.profit, r.profit) +
      w.roi * norm(m.roi, r.roi) + w.liquidity * m.liquidity
  end

  @doc "Probabilidad de que las órdenes sigan vigentes al llegar: `exp(−min / τ)`."
  @spec order_certainty(number()) :: float()
  def order_certainty(arrival_min), do: :math.exp(-arrival_min / GameRules.get(:order_tau_min))

  @doc """
  Factor de frescura de datos: 1 hasta 5 min, 0,8 a 15 min, 0,6 a 30 min (lineal) y
  0 después (datos excluidos, RF-4.9).
  """
  @spec data_certainty(number()) :: float()
  def data_certainty(age_min) do
    {fresh, degraded, stale} = GameRules.get(:staleness_minutes)

    cond do
      age_min <= fresh -> 1.0
      age_min <= degraded -> 1.0 - 0.2 * (age_min - fresh) / (degraded - fresh)
      age_min <= stale -> 0.8 - 0.2 * (age_min - degraded) / (stale - degraded)
      true -> 0.0
    end
  end

  @doc "TVS 0–100 = round(100 × utilidad × Certeza)."
  @spec tvs(float(), float()) :: non_neg_integer()
  def tvs(utility, certainty), do: round(100 * utility * certainty)
end
