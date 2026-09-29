defmodule Eth.Engine.OrderRules do
  @moduledoc """
  Reglas de las órdenes de mercado propias (F9, ERS §8.4, P-12). Funciones puras.

  - **Precios legales:** como máximo `:order_price_significant_digits` (4) cifras
    significativas y 0,01 ISK de precisión. Se trabaja en **centavos enteros** para no
    arrastrar errores de float: un precio es legal si sus centavos tienen a lo sumo 4
    cifras significativas (1.234,00 sí; 1.234,50 no).
  - **Superar** una orden de compra (`outbid/1`): el menor precio legal mayor que ella.
    **Superar** una de venta (`undercut/1`): el mayor precio legal menor que ella.
  - **Relist** (modificar el precio): `BR × max(0, V2 − V1) + (1 − RD) × BR × V2`, con
    `RD = 50 % + 6 % × Advanced Broker Relations` y V el valor de la orden.
  - **Límite de órdenes:** `5 + 4·Trade + 8·Retail + 16·Wholesale + 32·Tycoon`.
  - **Escrow:** una orden de compra inmoviliza `:buy_order_escrow_ratio` de su valor.

  Implementa: RF-4.16, RF-4.17.
  """

  alias Eth.GameRules

  @doc "¿El precio es legal para una orden? (a lo sumo 4 cifras significativas, ≥ 0,01)."
  @spec legal?(number()) :: boolean()
  def legal?(price) when is_number(price) do
    cents = to_cents(price)
    cents >= 1 and abs(price * 100 - cents) < 1.0e-6 and rem(cents, step(cents)) == 0
  end

  @doc "Menor precio legal estrictamente mayor que `price` (superar una compra)."
  @spec outbid(number()) :: float()
  def outbid(price) when is_number(price) and price >= 0 do
    cents = floor_cents(price)
    step = step(max(cents, 1))
    from_cents(div(cents, step) * step + step)
  end

  @doc """
  Mayor precio legal estrictamente menor que `price` (superar una venta). `nil` si no hay
  ninguno (el precio ya es el mínimo, 0,01 ISK).
  """
  @spec undercut(number()) :: float() | nil
  def undercut(price) when is_number(price) do
    cents = ceil_cents(price) - 1

    if cents < 1 do
      nil
    else
      step = step(cents)
      from_cents(div(cents, step) * step)
    end
  end

  @doc "Mayor precio legal menor o igual que `price` (redondeo hacia abajo)."
  @spec round_down(number()) :: float() | nil
  def round_down(price) when is_number(price) do
    cents = floor_cents(price)

    if cents < 1 do
      nil
    else
      step = step(cents)
      from_cents(div(cents, step) * step)
    end
  end

  @doc """
  Costo de modificar el precio de una orden (relist). `old_value` y `new_value` son los
  valores de la orden (precio × cantidad restante); `broker` en proporción.
  """
  @spec relist_fee(float(), number(), number(), 0..5) :: float()
  def relist_fee(broker, old_value, new_value, advanced_broker_relations) do
    discount =
      GameRules.get(:relist_discount_base) +
        GameRules.get(:relist_discount_per_level) * advanced_broker_relations

    broker * max(0.0, new_value - old_value) + (1 - discount) * broker * new_value
  end

  @doc "Máximo de órdenes activas según los niveles de habilidad (`%{skill_id => nivel}`)."
  @spec order_limit(%{optional(pos_integer()) => 0..5}) :: pos_integer()
  def order_limit(skills) do
    Enum.reduce(GameRules.get(:order_limit_per_level), GameRules.get(:order_limit_base), fn
      {skill_id, per_level}, acc -> acc + per_level * Map.get(skills, skill_id, 0)
    end)
  end

  @doc "ISK que inmoviliza una orden de compra (escrow)."
  @spec escrow(number()) :: float()
  def escrow(order_value), do: order_value * GameRules.get(:buy_order_escrow_ratio)

  ## Centavos

  # Paso legal para un precio de `cents` centavos: 10^(dígitos − 4), mínimo 1 centavo.
  defp step(cents) do
    digits = cents |> Integer.to_string() |> byte_size()
    Integer.pow(10, max(digits - GameRules.get(:order_price_significant_digits), 0))
  end

  defp to_cents(price), do: round(price * 100)
  # Tolerancia para precios que en float quedan apenas debajo o arriba del centavo.
  defp floor_cents(price), do: floor(price * 100 + 1.0e-6)
  defp ceil_cents(price), do: ceil(price * 100 - 1.0e-6)
  defp from_cents(cents), do: cents / 100
end
