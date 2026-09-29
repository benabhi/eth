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

  defp causes(plan, buys, sells, bought, sold) do
    [
      bought == 0 && "No hay compras del tipo en la estación de origen",
      (bought > 0 and bought < plan["quantity"]) &&
        "Se compró menos de lo planificado (#{bought} de #{plan["quantity"]})",
      (bought > 0 and avg(buys) > plan["avg_buy"] * 1.001) &&
        "Compra promedio más cara que la planificada",
      (sold > 0 and avg(sells) < plan["avg_sell"] * 0.999) &&
        "Venta promedio más barata que la planificada",
      Enum.any?(sells, &(&1.location_id != plan["destination_location_id"])) &&
        "Parte de la venta fue en otra estación",
      (bought > 0 and sold < bought) && "Quedan #{bought - sold} unidades sin vender"
    ]
    |> Enum.filter(&is_binary/1)
  end

  defp avg([]), do: 0.0
  defp avg(ts), do: sum(ts, &(&1.quantity * &1.unit_price)) / sum(ts, & &1.quantity)

  defp sum(list, fun), do: Enum.reduce(list, 0, &(fun.(&1) + &2))
end
