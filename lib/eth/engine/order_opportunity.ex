defmodule Eth.Engine.OrderOpportunity do
  @moduledoc """
  Candidato universal de la familia **por órdenes** entre estaciones (RF-4.1):

  - `:listing` (Listado): comprar a órdenes de venta del origen, llevar la carga a un hub
    y publicar ahí una orden de venta que supere a la mejor. Guarda el libro de ventas del
    origen (lo que se compra) y el del hub (la competencia de la orden propia).
  - `:buy_order` (compra por orden): publicar en un hub una orden de compra que supere a
    la mejor, esperar a que se llene y vender a órdenes de compra del destino. Guarda el
    libro de compras del hub (la competencia) y las compras del destino que cubren la
    estación de venta (lo que se vende).

  Los libros son `[{precio, volumen, order_id, emitida_unix, min_volume}]` del mejor al
  peor precio. El precio sugerido, la cantidad, el tiempo de ejecución y el beneficio se
  calculan en la consulta con los datos del piloto (`Eth.Engine.OrderQuery`).
  """

  alias Eth.Engine.Locations

  @enforce_keys [:id, :mode, :type_id, :type_name, :origin, :destination]
  defstruct [
    :id,
    :mode,
    :type_id,
    :type_name,
    :unit_volume,
    :origin,
    :destination,
    :hub_location_id,
    :jumps,
    :secure_jumps,
    :last_modified,
    buy_book: [],
    sell_book: []
  ]

  @type mode :: :listing | :buy_order
  @type t :: %__MODULE__{
          id: String.t(),
          mode: mode(),
          type_id: pos_integer(),
          type_name: String.t(),
          unit_volume: float(),
          origin: Locations.t(),
          destination: Locations.t(),
          hub_location_id: pos_integer(),
          jumps: non_neg_integer(),
          secure_jumps: non_neg_integer() | nil,
          last_modified: DateTime.t(),
          buy_book: list(),
          sell_book: list()
        }

  @doc "ID estable: modo, tipo, origen y destino."
  @spec id(mode(), pos_integer(), pos_integer(), pos_integer()) :: String.t()
  def id(mode, type_id, origin_id, destination_id),
    do: "#{if mode == :listing, do: "ls", else: "bo"}-#{type_id}-#{origin_id}-#{destination_id}"
end
