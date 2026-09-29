defmodule Eth.Routing do
  @moduledoc """
  API de ruteo (RF-2.4, RF-2.5): distancias en O(1) desde las matrices precomputadas y
  caminos concretos bajo demanda. Devuelve `nil` mientras el grafo no esté listo.

  Modos: `:shortest` (Rápida) y `:secure` (Segura, solo highsec). El modo Evasiva
  (`evasive_path/4`) evita las amenazas del radar sobre la restricción de cualquiera de los
  dos.

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

  @doc "Camino más corto del modo, reconstruido desde la matriz (rápido, sin búsqueda)."
  @spec matrix_path(pos_integer(), pos_integer(), Graph.mode()) :: [pos_integer()] | nil
  def matrix_path(from, to, mode \\ :shortest) do
    if g = graph(), do: Graph.matrix_path(g, from, to, mode)
  end

  @doc """
  Camino evasivo (RF-2.5): costo por sistema `1 + α × amenaza`, con la restricción de
  seguridad de `mode`. Si el camino corto no cruza ninguna amenaza, es el mismo (ningún
  camino cuesta menos que un salto por sistema) y no hace falta buscar.
  """
  @spec evasive_path(pos_integer(), pos_integer(), Graph.mode(), (pos_integer() -> float())) ::
          [pos_integer()] | nil
  def evasive_path(from, to, mode, threat) do
    with %Graph{} = g <- graph(),
         [_ | _] = short <- Graph.matrix_path(g, from, to, mode) do
      if Enum.all?(short, &(threat.(&1) == 0.0)) do
        short
      else
        alpha = Eth.GameRules.get(:evasive_alpha)
        Graph.weighted_path(g, from, to, mode, &(1 + alpha * threat.(&1)))
      end
    end
  end
end
