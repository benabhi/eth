defmodule Eth.Engine.Liquidity do
  @moduledoc """
  Filtro e índice de liquidez (RF-4.7). Funciones puras.

  - **Índice 0–1:** volumen diario de 7 días del destino frente a la cantidad a mover,
    con la misma normalización cóncava del TVS (`Eth.Engine.Score.norm/2`): mover una
    cantidad de hasta `:full_at_days` días de volumen vale 1. Sin historial, el valor
    neutro `:default_liquidity`.
  - **Ilíquido:** menos de `:min_days_traded` días con operaciones en 30. El Cazador lo
    marca o lo excluye según el filtro.

  En el modo directo la venta es a órdenes de compra existentes: la profundidad del
  destino ya limita la cantidad en el walk-the-book (RF-4.4), así que el índice mide
  cuánto pesa esa cantidad frente al mercado real. El tiempo estimado de venta del modo
  Listado llega con las órdenes propias (F9).

  Implementa: RF-4.7.
  """

  alias Eth.Engine.Score
  alias Eth.GameRules

  @doc "Índice de liquidez 0–1 para mover `quantity` unidades con estas estadísticas."
  @spec index(map() | nil, non_neg_integer()) :: float()
  def index(nil, _quantity), do: GameRules.get(:default_liquidity)
  def index(_stats, 0), do: 0.0

  def index(stats, quantity) do
    rules = GameRules.get(:liquidity)
    Score.norm(stats.volume_avg_7d / quantity, 1 / rules.full_at_days)
  end

  @doc "¿Tipo ilíquido? (`false` sin historial: no se sabe todavía)."
  @spec illiquid?(map() | nil) :: boolean()
  def illiquid?(nil), do: false
  def illiquid?(stats), do: stats.days_traded_30d < GameRules.get(:liquidity).min_days_traded
end
