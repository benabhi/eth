defmodule Eth.Tracking.Stages do
  @moduledoc """
  Máquina de etapas de un viaje (RF-7.2, ERS diagrama de M7). Función pura: recibe la
  etapa actual, el plan y las señales del piloto (ubicación y saldo) y devuelve la etapa
  siguiente.

  | De | A | Señal |
  |---|---|---|
  | planificado | hacia el origen | el piloto sale de donde estaba o fija los waypoints |
  | hacia el origen | comprado | atracado en el origen y el saldo bajó ≥ `:bought_share` de la inversión, o confirmación |
  | comprado | en tránsito | el piloto deja la estación de origen |
  | en tránsito | en destino | el piloto atraca en la estación de venta |
  | en destino | cerrado | el saldo subió ≥ `:sold_share` del ingreso, o confirmación |

  `/wallet/transactions` tiene 1 h de caché: la etapa en vivo sale de la ubicación (10 s) y
  del saldo (2 min); la reconciliación exacta llega después (RF-7.5).

  Implementa: RF-7.2.
  """

  alias Eth.GameRules

  @type status :: String.t()
  @type signals :: %{
          optional(:docked_at) => pos_integer() | nil,
          optional(:wallet) => float() | nil,
          optional(:moved) => boolean()
        }

  @doc """
  Etapa siguiente. `run` necesita `status`, `plan` (con `origin_location_id`,
  `destination_location_id`, `cost` y `revenue`) y `wallet_at_start`; `signals` trae dónde
  está atracado el piloto (`nil` en el espacio), el saldo actual y si se movió.
  """
  @spec next(map(), signals()) :: status()
  def next(%{status: "planned"} = run, signals) do
    if signals[:moved] or docked_at_origin?(run, signals), do: "to_origin", else: "planned"
  end

  def next(%{status: "to_origin"} = run, signals) do
    if docked_at_origin?(run, signals) and spent?(run, signals), do: "bought", else: "to_origin"
  end

  def next(%{status: "bought"} = run, signals) do
    if docked_at_origin?(run, signals), do: "bought", else: "in_transit"
  end

  def next(%{status: "in_transit"} = run, signals) do
    if signals[:docked_at] == plan(run, "destination_location_id"),
      do: "at_destination",
      else: "in_transit"
  end

  def next(%{status: "at_destination"} = run, signals) do
    if earned?(run, signals), do: "closed", else: "at_destination"
  end

  def next(%{status: status}, _signals), do: status

  @doc "Etapa a la que lleva una confirmación manual (\"compré\" / \"vendí\")."
  @spec confirm(status(), :bought | :sold) :: {:ok, status()} | :error
  def confirm(status, :bought) when status in ["planned", "to_origin"], do: {:ok, "bought"}

  def confirm(status, :sold) when status in ["bought", "in_transit", "at_destination"],
    do: {:ok, "closed"}

  def confirm(_status, _action), do: :error

  defp docked_at_origin?(run, signals),
    do: signals[:docked_at] != nil and signals[:docked_at] == plan(run, "origin_location_id")

  # El saldo bajó al menos la fracción configurada de la inversión planificada.
  defp spent?(%{wallet_at_start: start} = run, %{wallet: wallet})
       when is_number(start) and is_number(wallet) do
    start - wallet >= rules().bought_share * plan(run, "cost")
  end

  defp spent?(_run, _signals), do: false

  # El saldo subió al menos la fracción configurada del ingreso respecto de lo que quedó
  # después de comprar (saldo inicial − inversión).
  defp earned?(%{wallet_at_start: start} = run, %{wallet: wallet})
       when is_number(start) and is_number(wallet) do
    after_buy = start - plan(run, "cost")
    wallet - after_buy >= rules().sold_share * plan(run, "revenue")
  end

  defp earned?(_run, _signals), do: false

  defp plan(run, key), do: run.plan[key]
  defp rules, do: GameRules.get(:run)
end
