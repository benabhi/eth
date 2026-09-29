defmodule Eth.Engine.Fees do
  @moduledoc """
  Impuestos y comisiones de mercado (RF-4.5, ERS §8.4). Constantes en `Eth.GameRules`.

  - Arbitraje instantáneo (comprar a órdenes de venta y vender a órdenes de compra):
    solo se paga *sales tax*; comprar a una orden de venta no tiene comisión.
  - El broker fee solo aplica al **publicar** órdenes (modo Listado, v1.x).

  Implementa: RF-4.5.
  """

  alias Eth.GameRules

  @doc "Sales tax según el nivel de Accounting: 7,5 % × (1 − 0,11 × nivel)."
  @spec sales_tax(0..5) :: float()
  def sales_tax(accounting) when accounting in 0..5 do
    GameRules.get(:sales_tax_base) *
      (1 - GameRules.get(:accounting_reduction_per_level) * accounting)
  end

  @doc """
  Broker fee en estaciones NPC: 3 % − 0,3 % × Broker Relations − 0,03 % × standing de
  facción − 0,02 % × standing de corporación (standings sin modificar, −10…10).
  """
  @spec broker_fee_npc(0..5, number(), number()) :: float()
  def broker_fee_npc(broker_relations, faction_standing, corp_standing) do
    GameRules.get(:broker_fee_base) -
      GameRules.get(:broker_relations_reduction_per_level) * broker_relations -
      GameRules.get(:broker_faction_standing_coef) * faction_standing -
      GameRules.get(:broker_corp_standing_coef) * corp_standing
  end

  @doc "Sales tax más bajo posible (Accounting V): cota para el screening."
  @spec min_sales_tax() :: float()
  def min_sales_tax, do: sales_tax(5)
end
