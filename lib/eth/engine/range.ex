defmodule Eth.Engine.Range do
  @moduledoc """
  Elegibilidad por rango de órdenes de compra (RF-4.3, ERS §8.2). Función pura.

  Una orden de compra puede satisfacerse desde cualquier estación dentro de su rango:

  | `range` | Se puede vender desde |
  |---|---|
  | `:station` | la misma estación |
  | `:solarsystem` | cualquier estación del mismo sistema |
  | `1..40` | cualquier estación de la misma región a ≤ N saltos (ruta más corta) |
  | `:region` | cualquier estación de la misma región |

  Implementa: RF-4.3.
  """

  @type location :: %{
          location_id: pos_integer(),
          system_id: pos_integer(),
          region_id: pos_integer()
        }
  @type bid :: %{
          required(:location_id) => pos_integer(),
          required(:system_id) => pos_integer(),
          required(:region_id) => pos_integer(),
          required(:range) => :station | :solarsystem | :region | pos_integer()
        }

  @doc """
  ¿Se puede vender a `bid` desde `location`? `jumps` resuelve la distancia más corta
  entre dos sistemas (`nil` si no hay camino).
  """
  @spec covers?(bid(), location(), (pos_integer(), pos_integer() -> non_neg_integer() | nil)) ::
          boolean()
  def covers?(%{range: :station} = bid, location, _jumps),
    do: bid.location_id == location.location_id

  def covers?(%{range: :solarsystem} = bid, location, _jumps),
    do: bid.system_id == location.system_id

  def covers?(%{range: :region} = bid, location, _jumps), do: bid.region_id == location.region_id

  def covers?(%{range: n} = bid, location, jumps) when is_integer(n) do
    bid.region_id == location.region_id and
      case jumps.(bid.system_id, location.system_id) do
        nil -> false
        d -> d <= n
      end
  end
end
