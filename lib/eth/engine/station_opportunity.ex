defmodule Eth.Engine.StationOpportunity do
  @moduledoc """
  Candidato universal de station trading (RF-4.16): un tipo con órdenes de compra y de
  venta en la misma estación de un hub, cuyo diferencial deja margen con las comisiones
  más bajas posibles. Guarda el libro de la estación (hasta `:book_depth` órdenes por
  lado, del mejor al peor precio) para calcular en la consulta el precio sugerido, la
  competencia y el margen con las comisiones del piloto (y sin sus propias órdenes).
  """

  alias Eth.Engine.Locations
  alias Eth.Engine.Search

  @enforce_keys [:id, :type_id, :type_name, :location, :bids, :asks]
  defstruct [
    :id,
    :type_id,
    :type_name,
    :unit_volume,
    :location,
    :last_modified,
    search_text: "",
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
          search_text: String.t(),
          bids: [book_order()],
          asks: [book_order()]
        }

  @doc "Guarda el texto buscable de una lista (una vez al publicar la evaluación, RNF-1.1)."
  @spec index_search([t()]) :: [t()]
  def index_search(opps),
    do: Search.index(opps, &search_fields/1, &%{&1 | search_text: &2})

  @doc "Texto buscable: el guardado o, si falta, el calculado."
  @spec search_text(t()) :: String.t()
  def search_text(%__MODULE__{search_text: text}) when text != "", do: text
  def search_text(%__MODULE__{} = opp), do: Search.text(search_fields(opp))

  defp search_fields(opp),
    do: [opp.type_name, opp.location.name, opp.location.system_name, opp.location.region_name]

  @doc "ID estable entre ciclos: estación y tipo."
  @spec id(pos_integer(), pos_integer()) :: String.t()
  def id(location_id, type_id), do: "st-#{location_id}-#{type_id}"
end
