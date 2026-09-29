defmodule Eth.Engine.Shield do
  @moduledoc """
  Escudo anti-scam (RF-4.8, ERS §8.7). Función pura.

  Firma del *margin trading scam*: una orden de compra muy por encima del valor real (con
  escrow parcial) y el mismo ítem a la venta caro en otra estación. ESI no expone el dueño
  ni el escrow de las órdenes: la detección es estadística, contra la **mediana de los
  promedios diarios de 7 días** de cada región (30 días si en 7 hubo pocos días operados).

  | Regla | Condición | Resultado |
  |---|---|---|
  | AS-1 | compra > `:scam_bid_ratio` × mediana (destino) | `:scam` |
  | AS-2 | compra > `:suspicious_bid_ratio` × mediana | `:suspicious` |
  | AS-3 | sin historial: compra > `:global_price_ratio` × precio promedio global | `:suspicious` |
  | AS-4 | venta del origen > `:origin_ask_ratio` × mediana (origen) y AS-1/AS-2 | `:scam` |
  | AS-5 | `min_volume > 1` en una compra consumida y AS-2 | `:scam` |
  | AS-6 | compra creada hace menos de `:fresh_order_minutes` y AS-2 | `:scam` |
  | AS-7 | menos de `:min_days_traded` días operados en 30 | `:no_history` (ROI alto ⇒ `:suspicious`) |

  La otra mitad de AS-5 (ignorar la orden cuyo `min_volume` supera la cantidad asignable)
  la aplica `Eth.Engine.Book`. AS-8 (acceso a estructuras) es parte de la Certeza de
  acceso (F7).

  El estado final es el más grave; los motivos se devuelven en texto legible.

  Implementa: RF-4.8.
  """

  alias Eth.GameRules

  @type status :: :ok | :no_history | :suspicious | :scam
  @type verdict :: %{status: status(), reasons: [String.t()], ratio: float() | nil}

  @type input :: %{
          bid: float(),
          ask: float(),
          roi: float(),
          bid_min_volume: pos_integer(),
          bid_issued: DateTime.t() | nil,
          dest_stats: map() | nil,
          origin_stats: map() | nil,
          global_average: float() | nil,
          now: DateTime.t()
        }

  @severity %{ok: 0, no_history: 1, suspicious: 2, scam: 3}

  @doc "Evalúa una oportunidad. Ver la tabla de reglas en el `@moduledoc`."
  @spec evaluate(input()) :: verdict()
  def evaluate(input) do
    rules = GameRules.get(:anti_scam)

    case reference(input.dest_stats, rules) do
      nil -> without_history(input, rules)
      {median, window} -> with_history(input, median, window, rules)
    end
  end

  @doc "Factor de Certeza por estado (ERS §8.9: ok 1 · sin historial 0,7 · sospechoso 0,5 · scam 0)."
  @spec certainty(status()) :: float()
  def certainty(status), do: Map.fetch!(GameRules.get(:anti_scam).certainty, status)

  @doc "¿`a` es más grave que `b`?"
  @spec worse?(status(), status()) :: boolean()
  def worse?(a, b), do: @severity[a] > @severity[b]

  @doc """
  Mediana de referencia de una región: 7 días si hubo al menos `:min_days_7d` días
  operados, si no 30 días. `nil` si hay menos de `:min_days_traded` días en 30 (AS-7).
  """
  @spec reference(map() | nil, map()) :: {float(), 7 | 30} | nil
  def reference(nil, _rules), do: nil

  def reference(stats, rules) do
    days_7d = stats.daily_avg |> Enum.take(-7) |> Enum.count(&(&1 != nil))

    cond do
      stats.days_traded_30d < rules.min_days_traded -> nil
      days_7d >= rules.min_days_7d and stats.median_7d -> {stats.median_7d, 7}
      stats.median_30d -> {stats.median_30d, 30}
      true -> nil
    end
  end

  # AS-3 y AS-7: sin historial suficiente en el destino.
  defp without_history(input, rules) do
    days = (input.dest_stats && input.dest_stats.days_traded_30d) || 0

    base =
      if input.dest_stats,
        do: "Historial escaso: #{days} días con operaciones en 30",
        else: "Sin historial todavía"

    global_ratio = input.global_average && input.bid / input.global_average

    {status, reasons} =
      cond do
        global_ratio && global_ratio > rules.global_price_ratio ->
          {:suspicious, ["Compra a #{times(global_ratio)} el precio promedio global"]}

        input.roi > rules.no_history_max_roi ->
          {:suspicious, ["ROI de #{percent(input.roi)} sin historial que lo respalde"]}

        true ->
          {:no_history, []}
      end

    %{status: status, reasons: [base | reasons], ratio: nil}
  end

  defp with_history(input, median, window, rules) do
    ratio = input.bid / median
    compare = "Compra a #{times(ratio)} la mediana de #{window} días"

    cond do
      ratio > rules.scam_bid_ratio ->
        verdict(:scam, [compare | aggravating(input, rules)], ratio)

      ratio > rules.suspicious_bid_ratio ->
        case aggravating(input, rules) do
          [] -> verdict(:suspicious, [compare], ratio)
          extra -> verdict(:scam, [compare | extra], ratio)
        end

      true ->
        verdict(:ok, [], ratio)
    end
  end

  # AS-4, AS-5 y AS-6: señales que, junto con una compra inflada, confirman el scam.
  defp aggravating(input, rules) do
    [
      origin_inflated(input, rules),
      input.bid_min_volume > 1 &&
        "La compra exige al menos #{input.bid_min_volume} unidades por transacción",
      fresh_order(input, rules)
    ]
    |> Enum.filter(&is_binary/1)
  end

  defp origin_inflated(input, rules) do
    with {median, window} <- reference(input.origin_stats, rules),
         ratio when ratio > rules.origin_ask_ratio <- input.ask / median do
      "Venta en el origen a #{times(ratio)} la mediana de #{window} días"
    else
      _ -> nil
    end
  end

  defp fresh_order(%{bid_issued: nil}, _rules), do: nil

  defp fresh_order(input, rules) do
    minutes = DateTime.diff(input.now, input.bid_issued, :minute)
    if minutes < rules.fresh_order_minutes, do: "Orden creada hace #{age(minutes)}"
  end

  defp verdict(status, reasons, ratio), do: %{status: status, reasons: reasons, ratio: ratio}

  ## Formato de los motivos (español: coma decimal)

  defp times(x), do: decimal(x, 1) <> "×"
  defp percent(x), do: decimal(x * 100, 0) <> " %"

  defp age(minutes) when minutes < 60, do: "#{max(minutes, 0)} min"
  defp age(minutes), do: "#{div(minutes, 60)} h #{rem(minutes, 60)} min"

  defp decimal(x, 0), do: x |> round() |> Integer.to_string()

  defp decimal(x, places) do
    x |> :erlang.float_to_binary(decimals: places) |> String.replace(".", ",")
  end
end
