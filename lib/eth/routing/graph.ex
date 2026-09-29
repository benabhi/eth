defmodule Eth.Routing.Graph do
  @moduledoc """
  Grafo de navegación por stargates y matrices de distancia precomputadas (RF-2.4).

  - Solo K-space (IDs < 31000000), sin las regiones excluidas por configuración (Pochven,
    Zarzakh), y solo la componente conexa principal (la que contiene al sistema raíz,
    Jita): los sistemas aislados quedan fuera del ruteo.
  - Dos matrices de saltos de `n × n` bytes (≈ 29 MB cada una para ~5.400 sistemas):
    `:shortest` (Rápida, cualquier seguridad) y `:secure` (Segura, solo highsec).
    Valor 255 = inalcanzable. Consulta en O(1).
  - Caminos concretos bajo demanda con BFS, con lista opcional de sistemas a evitar.

  Funciones puras: construir y consultar no requiere procesos.

  Implementa: RF-2.4, RF-2.5.
  """

  @unreachable 255

  @enforce_keys [:ids, :index, :n, :adjacency, :highsec, :shortest, :secure]
  defstruct @enforce_keys

  @type mode :: :shortest | :secure
  @type t :: %__MODULE__{
          ids: tuple(),
          index: %{pos_integer() => non_neg_integer()},
          n: non_neg_integer(),
          adjacency: tuple(),
          highsec: tuple(),
          shortest: binary(),
          secure: binary()
        }

  @doc """
  Construye el grafo. `systems` es `id => %{region_id, security, neighbors}`.

  Opciones: `:root` (sistema raíz), `:excluded_region_ids`, `:highsec_min` (seguridad
  real mínima para highsec).
  """
  @spec build(map(), keyword()) :: t()
  def build(systems, opts) do
    excluded = MapSet.new(Keyword.fetch!(opts, :excluded_region_ids))
    highsec_min = Keyword.fetch!(opts, :highsec_min)

    routable? = fn id ->
      case systems do
        %{^id => %{region_id: region}} -> id < 31_000_000 and region not in excluded
        _ -> false
      end
    end

    component = connected_component(systems, Keyword.fetch!(opts, :root), routable?)
    ids = component |> Enum.sort() |> List.to_tuple()
    index = ids |> Tuple.to_list() |> Enum.with_index() |> Map.new()
    n = tuple_size(ids)

    adjacency =
      ids
      |> Tuple.to_list()
      |> Enum.map(fn id ->
        systems[id].neighbors |> Enum.filter(&Map.has_key?(index, &1)) |> Enum.map(&index[&1])
      end)
      |> List.to_tuple()

    highsec =
      ids
      |> Tuple.to_list()
      |> Enum.map(&(systems[&1].security >= highsec_min))
      |> List.to_tuple()

    %__MODULE__{
      ids: ids,
      index: index,
      n: n,
      adjacency: adjacency,
      highsec: highsec,
      shortest: matrix(adjacency, n, fn _i -> true end),
      secure: matrix(adjacency, n, &elem(highsec, &1))
    }
  end

  @doc "Saltos entre dos sistemas (`nil` si alguno no es ruteable o no hay camino)."
  @spec distance(t(), pos_integer(), pos_integer(), mode()) :: non_neg_integer() | nil
  def distance(%__MODULE__{} = graph, from, to, mode) do
    with {:ok, i} <- Map.fetch(graph.index, from),
         {:ok, j} <- Map.fetch(graph.index, to) do
      case :binary.at(Map.fetch!(graph, mode), i * graph.n + j) do
        @unreachable -> nil
        jumps -> jumps
      end
    else
      :error -> nil
    end
  end

  @doc """
  Camino concreto (lista de sistemas, incluidos origen y destino) o `nil`.
  `avoid` es una lista de sistemas que no se pueden atravesar (sí ser origen o destino).
  """
  @spec path(t(), pos_integer(), pos_integer(), mode(), [pos_integer()]) :: [pos_integer()] | nil
  def path(%__MODULE__{} = graph, from, to, mode, avoid \\ []) do
    with {:ok, i} <- Map.fetch(graph.index, from),
         {:ok, j} <- Map.fetch(graph.index, to) do
      avoided = avoid |> Enum.flat_map(&List.wrap(graph.index[&1])) |> MapSet.new()
      allowed = allowed_fun(graph, mode)

      allowed? = fn k ->
        allowed.(k) and (k in [i, j] or not MapSet.member?(avoided, k))
      end

      if allowed?.(i) and allowed?.(j) do
        graph.adjacency |> bfs_parents(i, j, allowed?) |> rebuild(i, j) |> to_ids(graph)
      end
    else
      :error -> nil
    end
  end

  @doc """
  Camino más corto del modo reconstruido desde la matriz de distancias, sin búsqueda:
  en cada paso se toma el vecino (permitido en el modo) que está a un salto menos del
  destino; a igualdad, el de menor índice (determinista). `nil` si no hay camino.
  Cuesta O(saltos × grado): pensado para miles de oportunidades por consulta.
  """
  @spec matrix_path(t(), pos_integer(), pos_integer(), mode()) :: [pos_integer()] | nil
  def matrix_path(%__MODULE__{} = graph, from, to, mode) do
    with {:ok, i} <- Map.fetch(graph.index, from),
         {:ok, j} <- Map.fetch(graph.index, to),
         matrix = Map.fetch!(graph, mode),
         d when d != @unreachable <- :binary.at(matrix, i * graph.n + j) do
      graph |> descend(matrix, i, j, d, allowed_fun(graph, mode), [i]) |> to_ids(graph)
    else
      _ -> nil
    end
  end

  defp descend(_graph, _matrix, _k, _j, 0, _allowed?, acc), do: Enum.reverse(acc)

  defp descend(graph, matrix, k, j, d, allowed?, acc) do
    next =
      graph.adjacency
      |> elem(k)
      |> Enum.filter(&(allowed?.(&1) and :binary.at(matrix, &1 * graph.n + j) == d - 1))
      |> Enum.min()

    descend(graph, matrix, next, j, d - 1, allowed?, [next | acc])
  end

  @doc """
  Camino de costo mínimo (Dijkstra) donde entrar a un sistema cuesta
  `cost.(system_id)` (≥ 1): el modo Evasiva usa `1 + α × amenaza` (RF-2.5). Respeta la
  restricción de seguridad de `mode`. `nil` si no hay camino.
  """
  @spec weighted_path(t(), pos_integer(), pos_integer(), mode(), (pos_integer() -> number())) ::
          [pos_integer()] | nil
  def weighted_path(%__MODULE__{} = graph, from, to, mode, cost) do
    with {:ok, i} <- Map.fetch(graph.index, from),
         {:ok, j} <- Map.fetch(graph.index, to),
         allowed? = allowed_fun(graph, mode),
         true <- allowed?.(i) and allowed?.(j) do
      queue = :gb_sets.singleton({0, i})

      graph
      |> dijkstra(queue, %{i => 0}, %{i => nil}, j, allowed?, cost)
      |> rebuild(i, j)
      |> to_ids(graph)
    else
      _ -> nil
    end
  end

  defp dijkstra(graph, queue, dist, parents, target, allowed?, cost) do
    if :gb_sets.is_empty(queue) do
      parents
    else
      {{d, k}, queue} = :gb_sets.take_smallest(queue)

      cond do
        k == target ->
          parents

        d > Map.fetch!(dist, k) ->
          dijkstra(graph, queue, dist, parents, target, allowed?, cost)

        true ->
          {queue, dist, parents} =
            graph.adjacency
            |> elem(k)
            |> Enum.filter(allowed?)
            |> Enum.reduce({queue, dist, parents}, fn m, {q, dist, parents} ->
              nd = d + cost.(elem(graph.ids, m))

              if nd < Map.get(dist, m, :infinity),
                do: {:gb_sets.add({nd, m}, q), Map.put(dist, m, nd), Map.put(parents, m, k)},
                else: {q, dist, parents}
            end)

          dijkstra(graph, queue, dist, parents, target, allowed?, cost)
      end
    end
  end

  defp to_ids(nil, _graph), do: nil
  defp to_ids(indexes, graph), do: Enum.map(indexes, &elem(graph.ids, &1))

  @doc "¿El sistema está en el grafo ruteable?"
  @spec routable?(t(), pos_integer()) :: boolean()
  def routable?(%__MODULE__{index: index}, id), do: Map.has_key?(index, id)

  defp allowed_fun(_graph, :shortest), do: fn _k -> true end
  defp allowed_fun(graph, :secure), do: &elem(graph.highsec, &1)

  ## Construcción

  # BFS desde la raíz sobre los sistemas ruteables.
  defp connected_component(systems, root, routable?) do
    if routable?.(root),
      do: walk([root], MapSet.new([root]), systems, routable?),
      else: MapSet.new()
  end

  defp walk([], seen, _systems, _routable?), do: seen

  defp walk([id | rest], seen, systems, routable?) do
    next = Enum.filter(systems[id].neighbors, &(routable?.(&1) and not MapSet.member?(seen, &1)))
    walk(next ++ rest, Enum.into(next, seen), systems, routable?)
  end

  # Una fila por sistema (BFS), calculadas en paralelo y concatenadas.
  defp matrix(adjacency, n, allowed?) do
    0..(n - 1)//1
    |> Task.async_stream(&row(adjacency, n, &1, allowed?),
      max_concurrency: System.schedulers_online(),
      ordered: true,
      timeout: :infinity
    )
    |> Enum.map(fn {:ok, row} -> row end)
    |> IO.iodata_to_binary()
  end

  defp row(adjacency, n, source, allowed?) do
    if allowed?.(source) do
      dist = :atomics.new(n, signed: false)
      # 0 = sin visitar; se guarda distancia + 1.
      :atomics.put(dist, source + 1, 1)
      bfs_fill(:queue.from_list([source]), adjacency, dist, allowed?)
      for k <- 1..n//1, into: <<>>, do: <<encode(:atomics.get(dist, k))>>
    else
      :binary.copy(<<@unreachable>>, n)
    end
  end

  defp encode(0), do: @unreachable
  defp encode(d), do: min(d - 1, @unreachable - 1)

  defp bfs_fill(queue, adjacency, dist, allowed?) do
    case :queue.out(queue) do
      {:empty, _} ->
        :ok

      {{:value, k}, queue} ->
        d = :atomics.get(dist, k + 1)
        queue = Enum.reduce(elem(adjacency, k), queue, &visit(&1, &2, d, dist, allowed?))
        bfs_fill(queue, adjacency, dist, allowed?)
    end
  end

  defp visit(m, queue, d, dist, allowed?) do
    if allowed?.(m) and :atomics.get(dist, m + 1) == 0 do
      :atomics.put(dist, m + 1, d + 1)
      :queue.in(m, queue)
    else
      queue
    end
  end

  ## Caminos

  defp bfs_parents(adjacency, from, to, allowed?) do
    search(:queue.from_list([from]), %{from => nil}, adjacency, to, allowed?)
  end

  defp search(queue, parents, adjacency, to, allowed?) do
    case :queue.out(queue) do
      {:empty, _} ->
        parents

      {{:value, ^to}, _} ->
        parents

      {{:value, k}, queue} ->
        {queue, parents} =
          Enum.reduce(elem(adjacency, k), {queue, parents}, &enqueue(&1, &2, k, allowed?))

        search(queue, parents, adjacency, to, allowed?)
    end
  end

  defp enqueue(m, {queue, parents}, from, allowed?) do
    if allowed?.(m) and not Map.has_key?(parents, m),
      do: {:queue.in(m, queue), Map.put(parents, m, from)},
      else: {queue, parents}
  end

  defp rebuild(parents, from, to) do
    if Map.has_key?(parents, to), do: trace(parents, to, [], from), else: nil
  end

  defp trace(_parents, from, acc, from), do: [from | acc]

  defp trace(parents, node, acc, from),
    do: trace(parents, Map.fetch!(parents, node), [node | acc], from)
end
