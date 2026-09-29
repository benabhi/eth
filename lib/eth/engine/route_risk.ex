defmodule Eth.Engine.RouteRisk do
  @moduledoc """
  Riesgo de ruta y su factor de Certeza (RF-4.12, ERS §8.9). Funciones puras sobre un
  contexto que se arma una vez por consulta (`context/0`).

  ```text
  C_ruta     = Π sobre los sistemas s del camino de (1 − p_s)
  p_s        = 1 − (1 − p_base_s) × (1 − p_alerta_s)
  p_base_s   = V[clase][roaming] × riesgo_base_s
  p_alerta_s = mín(0,95, amenaza_s × V[clase][tipo_s] × A_s)
  A_s        = tipo_s = hauler_gank ? clamp((log10(valor_carga) − 7) / 3, 0,05, 1) : 1
  ```

  `V` es la matriz de vulnerabilidad por clase de nave (Anexo B.8). Con el radar
  degradado, cada sistema low/null suma una penalización leve (RF-3.8).

  Implementa: RF-3.7, RF-3.8, RF-4.12.
  """

  alias Eth.{GameRules, Sde}
  alias Eth.Threat.{Baseline, Radar}

  @type context :: %{
          optional(:rules) => map(),
          base_risk: %{pos_integer() => float()},
          quiet: %{atom() => float()},
          alerts: %{pos_integer() => map()},
          degraded: boolean()
        }

  @doc "Contexto de una consulta: riesgo base, alertas vigentes y estado del radar."
  @spec context() :: context()
  def context do
    risk = Baseline.risk_snapshot()

    %{
      base_risk: risk.by_system,
      quiet: risk.quiet,
      alerts: Radar.hot_systems() |> Enum.filter(& &1.alert) |> Map.new(&{&1.system_id, &1}),
      degraded: Radar.degraded?(),
      rules: rules()
    }
  end

  # Reglas leídas una vez por consulta: `GameRules.get/1` copia la configuración en cada
  # llamada y aquí se evaluaría por cada sistema de cada camino.
  defp rules do
    radar = GameRules.get(:radar)

    %{
      vulnerability: GameRules.get(:vulnerability),
      max_alert: radar.max_alert_probability,
      penalty: radar.degraded_penalty,
      highsec_min: GameRules.get(:highsec_min_security)
    }
  end

  defp rules(ctx), do: Map.get_lazy(ctx, :rules, &rules/0)

  @doc "Atractivo de la carga para los gankers: 10M → 0,05 · 100M → 0,33 · 1B → 0,67 · 10B → 1."
  @spec attractiveness(number()) :: float()
  def attractiveness(value) when value <= 0, do: 0.05

  def attractiveness(value) do
    ((:math.log10(value) - 7) / 3) |> max(0.05) |> min(1.0)
  end

  @doc "Probabilidad de perder la nave en el sistema `s` (clase de nave y valor de carga)."
  @spec probability(pos_integer(), atom(), number(), context()) :: float()
  def probability(system_id, ship_class, cargo_value, ctx) do
    r = rules(ctx)
    probability(system_id, vulnerability(r, ship_class), cargo_value, ctx, r)
  end

  defp probability(system_id, v, cargo_value, ctx, r) do
    base = Map.get(ctx.base_risk, system_id) || Map.fetch!(ctx.quiet, band(system_id, r))
    p_base = v.roaming * base

    p_alert =
      case ctx.alerts do
        %{^system_id => %{threat: threat, classification: %{type: type}}} ->
          a = if type == :hauler_gank, do: attractiveness(cargo_value), else: 1.0
          min(r.max_alert, threat * v[type] * a)

        _ ->
          0.0
      end

    1 - (1 - p_base) * (1 - p_alert)
  end

  @doc "Factor de Certeza de un camino: Π (1 − p_s), con la penalización si está degradado."
  @spec certainty([pos_integer()], atom(), number(), context()) :: float()
  def certainty(path, ship_class, cargo_value, ctx) do
    r = rules(ctx)
    v = vulnerability(r, ship_class)

    Enum.reduce(path, 1.0, fn s, acc ->
      factor = 1 - probability(s, v, cargo_value, ctx, r)

      factor =
        if ctx.degraded and band(s, r) != :highsec, do: factor * r.penalty, else: factor

      acc * factor
    end)
  end

  @doc """
  Detalle por sistema para la sección Ruta del Cazador: seguridad, probabilidad y, si
  hay alerta, su tipo y descripción.
  """
  @spec details([pos_integer()], atom(), number(), context()) :: [map()]
  def details(path, ship_class, cargo_value, ctx) do
    Enum.map(path, fn s ->
      system = Sde.system(s) || %{}
      alert = ctx.alerts[s]

      %{
        system_id: s,
        name: system[:name],
        security: system[:security],
        probability: probability(s, ship_class, cargo_value, ctx),
        threat: alert && alert.threat,
        kills: alert && alert.kills,
        type: alert && alert.classification.type,
        description: alert && alert.classification.description
      }
    end)
  end

  defp vulnerability(r, ship_class),
    do: Map.get(r.vulnerability, ship_class, r.vulnerability.other)

  # Misma regla que `Eth.Sde.security_band/1`, con el umbral ya leído.
  defp band(system_id, r) do
    case Sde.system(system_id) do
      %{security: sec} when sec >= r.highsec_min -> :highsec
      %{security: sec} when sec > 0 -> :lowsec
      _ -> :nullsec
    end
  end
end
