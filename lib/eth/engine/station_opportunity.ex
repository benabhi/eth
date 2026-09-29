defmodule Eth.Engine.StationOpportunity do
  @moduledoc """
  Candidato universal de station trading (RF-4.16): un tipo con órdenes de compra y de
  venta en la misma estación de un hub, cuyo diferencial deja margen con las comisiones
  más bajas posibles. Guarda el libro de la estación (hasta `:book_depth` órdenes por
  lado, del mejor al peor precio) para calcular en la consulta el precio sugerido, la
  competencia y el margen con las comisiones del piloto (y sin sus propias órdenes).
  """

  alias Eth.Engine.Locations

  @enforce_keys [:id, :type_id, :type_name, :location, :bids, :asks]
  defstruct [
    :id,
    :type_id,
    :type_name,
    :unit_volume,
    :location,
    :last_modified,
    bids: [],
    asks: []
  ]

  @typedoc "Orden del libro: `{precio, volumen restante, order_id, emitida (unix), min_volume}`."
  @type book_order :: {float(), non_neg_integer(), pos_integer(), integer(), pos_integer()}

  @type t :: %__MODULE__{
          id: String.t(),
          type_id: pos_integer(),
          type_name: String.t(),
          unit_volume: float(),
          location: Locations.t(),
          last_modified: DateTime.t(),
          bids: [book_order()],
          asks: [book_order()]
        }

  @doc "ID estable entre ciclos: estación y tipo."
  @spec id(pos_integer(), pos_integer()) :: String.t()
  def id(location_id, type_id), do: "st-#{location_id}-#{type_id}"
end
