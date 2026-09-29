defmodule Eth.Routing do
  @moduledoc """
  API de ruteo (RF-2.4, RF-2.5): distancias en O(1) desde las matrices precomputadas y
  caminos concretos bajo demanda. Devuelve `nil` mientras el grafo no esté listo.

  Modos: `:shortest` (Rápida) y `:secure` (Segura, solo highsec). El modo Evasiva llega
  con el radar de amenazas (F6).

  Implementa: RF-2.4, RF-2.5.
  """

  alias Eth.Routing.Graph

  @doc "Grafo vigente (`nil` si todavía no se cargó)."
  @spec graph() :: Graph.t() | nil
  def graph, do: :persistent_term.get({__MODULE__, :graph}, nil)

  @doc "Saltos entre dos sistemas en un modo (`nil` si no hay grafo o no hay camino)."
  @spec distance(pos_integer(), pos_integer(), Graph.mode()) :: non_neg_integer() | nil
  def distance(from, to, mode \\ :shortest) do
    if g = graph(), do: Graph.distance(g, from, to, mode)
  end

  @doc "Camino (lista de sistemas) evitando opcionalmente algunos sistemas."
  @spec path(pos_integer(), pos_integer(), Graph.mode(), [pos_integer()]) ::
          [pos_integer()] | nil
  def path(from, to, mode \\ :shortest, avoid \\ []) do
    if g = graph(), do: Graph.path(g, from, to, mode, avoid)
  end
end
