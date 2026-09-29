defmodule Eth.Engine.SaleQuote do
  @moduledoc """
  Cotización de venta de una carga ya comprada (RF-7.3). Función pura sobre las órdenes de
  compra vigentes de un tipo: para cada estación candidata, cuánto se cobra vendiendo
  `quantity` unidades a las órdenes que la alcanzan por rango (RF-4.3), de mayor a menor
  precio y respetando el `min_volume` de cada orden.

  Sirve para revalidar el destino de un viaje en curso y para sugerir otro mejor.

  Implementa: RF-7.3.
  """

  alias Eth.Engine.Range

  @type bid :: %{
          price: float(),
          location_id: pos_integer(),
          system_id: pos_integer(),
          region_id: pos_integer(),
          range: term(),
          volume: pos_integer(),
          min_volume: pos_integer()
        }

  @type quote_result :: %{
          location_id: pos_integer(),
          system_id: pos_integer(),
          quantity: non_neg_integer(),
          gross: float(),
          net: float()
        }

  @doc """
  Cotiza la venta en `location` (`%{location_id, system_id, region_id}`) con las órdenes `bids`.
  `tax`: sales tax del piloto; `jumps`: función de distancia para el rango.
  """
  @spec at(map(), [bid()], pos_integer(), float(), (pos_integer(), pos_integer() -> term())) ::
          quote_result()
  def at(location, bids, quantity, tax, jumps) do
    {sold, gross} =
      bids
      |> Enum.filter(&Range.covers?(&1, location, jumps))
      |> Enum.sort_by(& &1.price, :desc)
      |> Enum.reduce_while({0, 0.0}, fn bid, {sold, gross} ->
        take = min(bid.volume, quantity - sold)

        cond do
          take <= 0 -> {:halt, {sold, gross}}
          take < bid.min_volume -> {:cont, {sold, gross}}
          true -> {:cont, {sold + take, gross + take * bid.price}}
        end
      end)

    %{
      location_id: location.location_id,
      system_id: location.system_id,
      quantity: sold,
      gross: gross,
      net: gross * (1 - tax)
    }
  end

  @doc """
  Cotiza en cada estación donde hay órdenes de compra del tipo y devuelve las cotizaciones
  de mayor a menor ingreso neto (las que no venden nada se descartan).
  """
  @spec best([bid()], pos_integer(), float(), (pos_integer(), pos_integer() -> term())) ::
          [quote_result()]
  def best(bids, quantity, tax, jumps) do
    bids
    |> Enum.map(&Map.take(&1, [:location_id, :system_id, :region_id]))
    |> Enum.uniq_by(& &1.location_id)
    |> Enum.map(&at(&1, bids, quantity, tax, jumps))
    |> Enum.filter(&(&1.quantity > 0))
    |> Enum.sort_by(& &1.net, :desc)
  end
end
