defmodule Eth.Market.RateWindow do
  @moduledoc """
  Ventana deslizante de requests: garantiza que nunca haya más de `max` en cualquier
  intervalo de `window_ms` (RF-1.12: historial ≤ 250 req/min, RNF-3.5). Función pura:
  los instantes son milisegundos monotónicos que maneja quien la usa.
  """

  @enforce_keys [:max, :window_ms]
  defstruct [:max, :window_ms, :stamps, count: 0]

  @type t :: %__MODULE__{
          max: pos_integer(),
          window_ms: pos_integer(),
          stamps: :queue.queue(integer()),
          count: non_neg_integer()
        }

  @doc "Ventana vacía."
  @spec new(pos_integer(), pos_integer()) :: t()
  def new(max, window_ms), do: %__MODULE__{max: max, window_ms: window_ms, stamps: :queue.new()}

  @doc """
  Intenta registrar un request en `now`: `{:ok, ventana}` si entra, o `{:wait, ms}` con
  los milisegundos hasta que se libere un lugar.
  """
  @spec take(t(), integer()) :: {:ok, t()} | {:wait, pos_integer()}
  def take(%__MODULE__{} = w, now) do
    w = expire(w, now)

    if w.count < w.max do
      {:ok, %{w | stamps: :queue.in(now, w.stamps), count: w.count + 1}}
    else
      {:value, oldest} = :queue.peek(w.stamps)
      {:wait, max(oldest + w.window_ms - now, 1)}
    end
  end

  @doc "Requests registrados en la ventana que termina en `now`."
  @spec count(t(), integer()) :: non_neg_integer()
  def count(%__MODULE__{} = w, now), do: expire(w, now).count

  # Descarta los instantes que ya salieron de la ventana (now − window_ms, now].
  defp expire(w, now) do
    case :queue.peek(w.stamps) do
      {:value, stamp} when stamp <= now - w.window_ms ->
        expire(%{w | stamps: :queue.drop(w.stamps), count: w.count - 1}, now)

      _ ->
        w
    end
  end
end
