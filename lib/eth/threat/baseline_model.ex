defmodule Eth.Threat.BaselineModel do
  @moduledoc """
  Línea base del radar a partir de la actividad horaria (RF-3.4, RF-3.7, ERS §8.8).
  Funciones puras.

  - **λ por franja horaria UTC** (kills esperadas en una ventana `W`): promedio de
    `ship_kills + pod_kills` del sistema en esa hora del día, sobre los días muestreados,
    ÷ (60 / W). Con menos de `:baseline_min_days` muestras en la franja: promedio general
    del sistema. Sin muestras: *prior* por banda de seguridad. Mínimo `:lambda_min`.
  - **Riesgo base:** `ship_kills / (saltos + k)` de los días de la línea base (suavizado
    para sistemas con poco tráfico), con tope `:base_risk_max`. Sin muestras: *prior* por
    banda. Una ruta por lowsec nunca es gratis.

  Un sistema ausente en una hora muestreada tuvo 0 kills (ESI solo lista los que tienen
  actividad): por eso se cuentan las horas muestreadas aparte.

  Implementa: RF-3.4, RF-3.7.
  """

  alias Eth.{GameRules, Sde}

  @type activity :: %{
          optional(pos_integer()) => %{
            by_hour: %{(0..23) => non_neg_integer()},
            kills: non_neg_integer(),
            ship_kills: non_neg_integer(),
            jumps: non_neg_integer()
          }
        }

  @type entry :: %{lambda: tuple(), base_risk: float()}

  @doc """
  Calcula la línea base de cada sistema con actividad. `kill_samples` son las horas
  muestreadas por franja (`%{hora_del_día => cantidad}`) y `jump_samples` la cantidad de
  horas con saltos muestreados.
  """
  @spec compute(activity(), %{(0..23) => non_neg_integer()}, non_neg_integer()) ::
          %{pos_integer() => entry()}
  def compute(activity, kill_samples, jump_samples) do
    Map.new(activity, fn {system_id, a} ->
      {system_id,
       %{
         lambda: lambdas(a, kill_samples, band(system_id)),
         base_risk: base_risk(a, jump_samples, band(system_id))
       }}
    end)
  end

  @doc "Línea base de un sistema sin actividad registrada."
  @spec quiet(pos_integer(), %{(0..23) => non_neg_integer()}, non_neg_integer()) :: entry()
  def quiet(system_id, kill_samples, jump_samples),
    do: quiet_band(band(system_id), kill_samples, jump_samples)

  @doc "Línea base sin actividad para una banda (solo depende de la banda y las muestras)."
  @spec quiet_band(atom(), %{(0..23) => non_neg_integer()}, non_neg_integer()) :: entry()
  def quiet_band(band, kill_samples, jump_samples) do
    empty = %{by_hour: %{}, kills: 0, ship_kills: 0, jumps: 0}

    %{
      lambda: lambdas(empty, kill_samples, band),
      base_risk: base_risk(empty, jump_samples, band)
    }
  end

  defp lambdas(a, kill_samples, band) do
    r = rules()
    per_window = 60 / r.window_min
    total = kill_samples |> Map.values() |> Enum.sum()

    0..23
    |> Enum.map(fn hour ->
      slot = Map.get(kill_samples, hour, 0)

      lambda =
        cond do
          slot >= r.baseline_min_days -> Map.get(a.by_hour, hour, 0) / slot / per_window
          total > 0 -> a.kills / total / per_window
          true -> r.lambda_prior[band]
        end

      max(lambda, r.lambda_min)
    end)
    |> List.to_tuple()
  end

  defp base_risk(a, jump_samples, band) do
    r = rules()

    if jump_samples > 0 do
      min(a.ship_kills / (a.jumps + r.base_risk_smoothing_jumps), r.base_risk_max)
    else
      r.base_risk_prior[band]
    end
  end

  @doc "Banda de seguridad de un sistema (`:nullsec` si no se conoce)."
  @spec band(pos_integer()) :: :highsec | :lowsec | :nullsec
  def band(system_id) do
    case Sde.system(system_id) do
      %{security: sec} -> Sde.security_band(sec)
      nil -> :nullsec
    end
  end

  defp rules, do: GameRules.get(:radar)
end
