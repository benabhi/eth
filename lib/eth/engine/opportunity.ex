defmodule Eth.Engine.Opportunity do
  @moduledoc """
  Oportunidad de arbitraje instantáneo **universal**: calculada sin contexto personal,
  con el sales tax del modo invitado y sin límites de capital ni bodega (RF-4.14). La
  personalización (impuestos reales, capital, bodega, triángulo de ruta, TVS) se aplica
  en tiempo de consulta con `Eth.Engine.Query`.

  `asks` y `bids` guardan solo las órdenes consumidas por el recorrido: alcanzan para
  recalcular con límites (la cantidad con límites nunca es mayor).
  """

  alias Eth.Engine.Locations

  @enforce_keys [:id, :type_id, :type_name, :unit_volume, :origin, :destination]
  defstruct [
    :id,
    :type_id,
    :type_name,
    :unit_volume,
    :origin,
    :destination,
    :quantity,
    :cost,
    :revenue,
    :tax,
    :profit,
    :avg_buy,
    :avg_sell,
    :jumps,
    :secure_jumps,
    :last_modified,
    remote_sale: false,
    asks: [],
    bids: []
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          type_id: pos_integer(),
          type_name: String.t(),
          unit_volume: float(),
          origin: Locations.t(),
          destination: Locations.t(),
          quantity: non_neg_integer(),
          cost: float(),
          revenue: float(),
          tax: float(),
          profit: float(),
          avg_buy: float(),
          avg_sell: float(),
          jumps: non_neg_integer(),
          secure_jumps: non_neg_integer() | nil,
          last_modified: DateTime.t(),
          remote_sale: boolean(),
          asks: [{float(), pos_integer()}],
          bids: [{float(), pos_integer(), pos_integer()}]
        }

  @doc "ID estable entre ciclos: modo, tipo, ubicación de compra y de venta (RF-4.9)."
  @spec id(pos_integer(), pos_integer(), pos_integer()) :: String.t()
  def id(type_id, origin_id, destination_id) do
    :crypto.hash(:sha256, "instant:#{type_id}:#{origin_id}:#{destination_id}")
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 16)
  end
end
