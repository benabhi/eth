defmodule Eth.Tracking.Reconcile do
  @moduledoc """
  Cierre de un viaje con las transacciones de la billetera (RF-7.5). Función pura.

  Toma las transacciones del tipo del plan dentro de la ventana del viaje (desde el
  inicio hasta el cierre más `:reconcile_grace_min`): las **compras** en la estación de
  origen y las **ventas** en la de destino (o en cualquier estación, si el piloto vendió en
  otra: se informa como causa). El beneficio real es `ingresos − compras − impuestos`,
  donde el *sales tax* se estima con la tasa del plan (el diario de la billetera lo trae
  aparte y no se lee en v1).

  Implementa: RF-7.5.
  """

  @type result :: %{
          bought_quantity: non_neg_integer(),
          sold_quantity: non_neg_integer(),
          cost: float(),
          gross: float(),
          tax: float(),
          profit: float(),
          deviation: float() | nil,
          complete: boolean(),
          causes: [String.t()]
        }

  @doc """
  Reconcilia. `plan` usa claves de string (`type_id`, `quantity`, `origin_location_id`,
  `destination_location_id`, `profit`, `tax_rate`, `avg_buy`, `avg_sell`); `transactions`
  son las del personaje en la ventana del viaje.
  """
  @spec run(map(), [map()]) :: result()
  def run(plan, transactions) do
    of_type = Enum.filter(transactions, &(&1.type_id == plan["type_id"]))
    buys = Enum.filter(of_type, &(&1.is_buy and &1.location_id == plan["origin_location_id"]))
    sells = Enum.reject(of_type, & &1.is_buy)

    bought = sum(buys, & &1.quantity)
    sold = sum(sells, & &1.quantity)
    cost = sum(buys, &(&1.quantity * &1.unit_price)) / 1
    gross = sum(sells, &(&1.quantity * &1.unit_price)) / 1
    tax = gross * (plan["tax_rate"] || 0.0)
    profit = gross - tax - cost
    predicted = plan["profit"]

    %{
      bought_quantity: bought,
      sold_quantity: sold,
      cost: cost,
      gross: gross,
      tax: tax,
      profit: profit,
      deviation: if(predicted && predicted != 0, do: (profit - predicted) / abs(predicted)),
      complete: bought > 0 and sold >= bought,
      causes: causes(plan, buys, sells, bought, sold)
    }
  end

  # Cada chequeo devuelve el texto de la causa o `nil`.
  defp causes(plan, buys, sells, bought, sold) do
    ctx = %{plan: plan, buys: buys, sells: sells, bought: bought, sold: sold}

    [&no_buys/1, &short_buy/1, &expensive_buy/1, &cheap_sale/1, &elsewhere/1, &unsold/1]
    |> Enum.map(& &1.(ctx))
    |> Enum.reject(&is_nil/1)
  end

  defp no_buys(%{bought: 0}), do: "No hay compras del tipo en la estación de origen"
  defp no_buys(_ctx), do: nil

  defp short_buy(%{bought: b, plan: plan}) when b > 0,
    do:
      if(b < plan["quantity"],
        do: "Se compró menos de lo planificado (#{b} de #{plan["quantity"]})"
      )

  defp short_buy(_ctx), do: nil

  defp expensive_buy(%{bought: b, buys: buys, plan: plan}) when b > 0,
    do: if(avg(buys) > plan["avg_buy"] * 1.001, do: "Compra promedio más cara que la planificada")

  defp expensive_buy(_ctx), do: nil

  defp cheap_sale(%{sold: s, sells: sells, plan: plan}) when s > 0,
    do:
      if(avg(sells) < plan["avg_sell"] * 0.999,
        do: "Venta promedio más barata que la planificada"
      )

  defp cheap_sale(_ctx), do: nil

  defp elsewhere(%{sells: sells, plan: plan}) do
    if Enum.any?(sells, &(&1.location_id != plan["destination_location_id"])),
      do: "Parte de la venta fue en otra estación"
  end

  defp unsold(%{bought: b, sold: s}) when b > 0 and s < b,
    do: "Quedan #{b - s} unidades sin vender"

  defp unsold(_ctx), do: nil

  defp avg([]), do: 0.0
  defp avg(ts), do: sum(ts, &(&1.quantity * &1.unit_price)) / sum(ts, & &1.quantity)

  defp sum(list, fun), do: Enum.reduce(list, 0, &(fun.(&1) + &2))
end
