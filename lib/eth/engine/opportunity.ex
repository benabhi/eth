defmodule Eth.Engine.Opportunity do
  @moduledoc """
  Oportunidad de arbitraje instantáneo **universal**: calculada sin contexto personal,
  con el sales tax del modo invitado y sin límites de capital ni bodega (RF-4.14). La
  personalización (impuestos reales, capital, bodega, triángulo de ruta, TVS) se aplica
  en tiempo de consulta con `Eth.Engine.Query`.

  `asks` y `bids` guardan solo las órdenes consumidas por el recorrido: alcanzan para
  recalcular con límites (la cantidad con límites nunca es mayor). `bid_issued` es la
  creación de la orden de compra más reciente del rango consumido (anti-scam AS-6).
  """

  alias Eth.Engine.{Locations, Search}

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
    :bid_issued,
    remote_sale: false,
    search_text: "",
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
          bid_issued: DateTime.t() | nil,
          remote_sale: boolean(),
          search_text: String.t(),
          asks: [{float(), pos_integer()}],
          bids: [{float(), pos_integer(), pos_integer()}]
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
      opp.origin.region_name,
      opp.destination.name,
      opp.destination.system_name,
      opp.destination.region_name
    ]
  end

  @doc "ID estable entre ciclos: modo, tipo, ubicación de compra y de venta (RF-4.9)."
  @spec id(pos_integer(), pos_integer(), pos_integer()) :: String.t()
  def id(type_id, origin_id, destination_id) do
    :crypto.hash(:sha256, "instant:#{type_id}:#{origin_id}:#{destination_id}")
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 16)
  end
end
