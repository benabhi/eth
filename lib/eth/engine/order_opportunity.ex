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
  alias Eth.Engine.Search

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
    search_text: "",
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
          search_text: String.t(),
          buy_book: list(),
          sell_book: list()
        }

  @doc "Guarda el texto buscable de una lista (una vez al publicar la evaluación, RNF-1.1)."
  @spec index_search([t()]) :: [t()]
  def index_search(opps),
    do: Search.index(opps, &search_fields/1, &%{&1 | search_text: &2})

  @doc "Texto buscable: el guardado o, si falta, el calculado."
  @spec search_text(t()) :: String.t()
  def search_text(%__MODULE__{search_text: text}) when text != "", do: text
  def search_text(%__MODULE__{} = opp), do: Search.text(search_fields(opp))

  defp search_fields(opp) do
    [
      opp.type_name,
      opp.origin.name,
      opp.origin.system_name,
      opp.destination.name,
      opp.destination.system_name
    ]
  end

  @doc "ID estable: modo, tipo, origen y destino."
  @spec id(mode(), pos_integer(), pos_integer(), pos_integer()) :: String.t()
  def id(mode, type_id, origin_id, destination_id),
    do: "#{if mode == :listing, do: "ls", else: "bo"}-#{type_id}-#{origin_id}-#{destination_id}"
end
