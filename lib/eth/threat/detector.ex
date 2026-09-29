defmodule Eth.Threat.Detector do
  @moduledoc """
  Intensidad, detección por umbral adaptativo e índice de amenaza (RF-3.3, RF-3.5, RF-3.7,
  ERS §8.8). Funciones puras.

  ```text
  peso_i  = 2^(−Δt_i / h)                        # h: vida media
  m_i     = 1 × (1,5 si la víctima es de transporte) × (1,5 si fue en un stargate)
  I_s     = Σ peso_i × m_i                       # kills PvP dentro de la ventana W
  N_s     = cantidad de kills en W
  alerta  ⇔ N_s ≥ min_kills  y  P(X ≥ N_s | Poisson(λ_s)) < p_value
  amenaza = alerta ? clamp((I_s − λ_s) / (I_s + 2), 0,3, 1) : 0
  ```

  Una muerte aislada nunca genera una alerta: hacen falta al menos `min_kills`.

  Implementa: RF-3.3, RF-3.5, RF-3.7.
  """

  alias Eth.GameRules
  alias Eth.Threat.Killmail

  @doc "Kills dentro de la ventana que termina en `now`."
  @spec in_window([Killmail.t()], DateTime.t()) :: [Killmail.t()]
  def in_window(kills, now) do
    from = DateTime.add(now, -rules().window_min * 60, :second)
    Enum.filter(kills, &(DateTime.compare(&1.time, from) != :lt))
  end

  @doc "Intensidad `I_s` con decaimiento exponencial y multiplicadores (§8.8)."
  @spec intensity([Killmail.t()], DateTime.t()) :: float()
  def intensity(kills, now) do
    r = rules()

    Enum.reduce(kills, 0.0, fn kill, acc ->
      age_min = max(DateTime.diff(now, kill.time, :second), 0) / 60
      weight = :math.pow(2, -age_min / r.half_life_min)

      m =
        if(kill.victim_transport, do: r.hauler_weight, else: 1) *
          if(kill.gate_id, do: r.gate_weight, else: 1)

      acc + weight * m
    end)
  end

  @doc "P(X ≥ n) para X ~ Poisson(λ)."
  @spec poisson_tail(non_neg_integer(), number()) :: float()
  def poisson_tail(n, _lambda) when n <= 0, do: 1.0

  def poisson_tail(n, lambda) do
    # 1 − Σ_{k<n} e^−λ λ^k / k!, con los términos calculados de forma incremental.
    {below, _term} =
      Enum.reduce(1..(n - 1)//1, {:math.exp(-lambda), :math.exp(-lambda)}, fn k, {sum, term} ->
        term = term * lambda / k
        {sum + term, term}
      end)

    max(1.0 - below, 0.0)
  end

  @doc "¿Alerta? `n` kills en la ventana frente a λ esperadas."
  @spec alert?(non_neg_integer(), number()) :: boolean()
  def alert?(n, lambda) do
    r = rules()
    n >= r.min_kills and poisson_tail(n, lambda) < r.p_value
  end

  @doc "Índice de amenaza 0–1 de un sistema (0 sin alerta)."
  @spec threat(boolean(), float(), number()) :: float()
  def threat(false, _intensity, _lambda), do: 0.0

  def threat(true, intensity, lambda) do
    raw = (intensity - lambda) / (intensity + 2)
    raw |> max(0.3) |> min(1.0)
  end

  defp rules, do: GameRules.get(:radar)
end
