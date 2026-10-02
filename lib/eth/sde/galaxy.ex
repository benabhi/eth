defmodule Eth.Sde.Galaxy do
  @moduledoc """
  Geometría del mapa del Centro de control (RF-8.2): posiciones 2D de las regiones y de
  los sistemas de una región, y sus conexiones por stargate. Funciones puras sobre los
  sistemas del SDE (`Eth.Sde.Processor`).

  - **Vista desde arriba**, como el mapa del juego: el eje X del SDE va al Este y el Z al
    Norte, así que en pantalla `x = X` e `y = −Z` (en SVG la `y` crece hacia abajo).
  - **Regiones:** cada una en el centro de sus sistemas; dos regiones se unen si algún
    stargate cruza de una a la otra. Solo el espacio conocido (sin agujeros de gusano ni
    Abyss).
  - **Sistemas de una región:** su posición y los stargates internos.
  - Todo se escala a un lienzo de `@width × @height` con margen, conservando la
    proporción.

  Implementa: RF-8.2.
  """

  @width 1000
  @height 600
  @pad 36

  @typedoc "Punto del mapa: región o sistema, ya en coordenadas del lienzo."
  @type point :: %{
          required(:id) => pos_integer(),
          required(:name) => String.t(),
          required(:x) => float(),
          required(:y) => float(),
          optional(:security) => float()
        }

  @type layout :: %{
          nodes: [point()],
          links: [{pos_integer(), pos_integer()}],
          width: pos_integer(),
          height: pos_integer()
        }

  # Regiones del espacio conocido: 10000001…; los agujeros de gusano empiezan en 11000001.
  defguardp known_space?(region_id)
            when is_integer(region_id) and region_id >= 10_000_000 and region_id < 11_000_000

  @doc """
  Regiones del espacio conocido con posición (el centro de sus sistemas) y las uniones
  entre las que comparten un stargate. `systems` y `regions` como en el SDE procesado.
  """
  @spec regions(%{pos_integer() => map()}, %{pos_integer() => map()}) :: layout()
  def regions(systems, regions) do
    centers =
      systems
      |> Enum.filter(fn {_id, s} -> known_space?(s.region_id) and positioned?(s) end)
      |> Enum.group_by(fn {_id, s} -> s.region_id end, fn {_id, s} -> {s.x, -s.z} end)
      |> Map.new(fn {region_id, points} -> {region_id, centroid(points)} end)

    links =
      for {_id, s} <- systems,
          Map.has_key?(centers, s.region_id),
          neighbor_id <- Map.get(s, :neighbors, []),
          other = Map.get(systems, neighbor_id),
          other != nil and other.region_id != s.region_id,
          Map.has_key?(centers, other.region_id),
          uniq: true,
          do: pair(s.region_id, other.region_id)

    nodes =
      for {region_id, {x, y}} <- centers do
        %{id: region_id, name: region_name(regions, region_id), x: x, y: y}
      end

    fit(nodes, links)
  end

  @doc "Sistemas de una región con su posición y seguridad, y los stargates entre ellos."
  @spec region(%{pos_integer() => map()}, pos_integer()) :: layout()
  def region(systems, region_id) do
    members =
      for {id, s} <- systems, s.region_id == region_id, positioned?(s), into: %{}, do: {id, s}

    nodes =
      for {id, s} <- members do
        %{id: id, name: s.name, security: s.security, x: s.x, y: -s.z}
      end

    links =
      for {id, s} <- members,
          neighbor_id <- Map.get(s, :neighbors, []),
          Map.has_key?(members, neighbor_id),
          uniq: true,
          do: pair(id, neighbor_id)

    fit(nodes, links)
  end

  defp positioned?(system), do: is_number(Map.get(system, :x)) and is_number(Map.get(system, :z))

  defp region_name(regions, region_id) do
    case Map.get(regions, region_id) do
      %{name: name} -> name
      _ -> Integer.to_string(region_id)
    end
  end

  defp pair(a, b), do: {min(a, b), max(a, b)}

  defp centroid(points) do
    n = length(points)
    {sx, sy} = Enum.reduce(points, {0.0, 0.0}, fn {x, y}, {ax, ay} -> {ax + x, ay + y} end)
    {sx / n, sy / n}
  end

  # Escala al lienzo conservando la proporción y centra el dibujo. Las uniones quedan solo
  # entre puntos presentes.
  defp fit([], _links), do: %{nodes: [], links: [], width: @width, height: @height}

  defp fit(nodes, links) do
    {min_x, max_x} = nodes |> Enum.map(& &1.x) |> Enum.min_max()
    {min_y, max_y} = nodes |> Enum.map(& &1.y) |> Enum.min_max()
    span_x = max(max_x - min_x, 1.0)
    span_y = max(max_y - min_y, 1.0)
    scale = min((@width - 2 * @pad) / span_x, (@height - 2 * @pad) / span_y)
    offset_x = (@width - span_x * scale) / 2
    offset_y = (@height - span_y * scale) / 2

    scaled =
      Enum.map(nodes, fn node ->
        %{
          node
          | x: Float.round(offset_x + (node.x - min_x) * scale, 1),
            y: Float.round(offset_y + (node.y - min_y) * scale, 1)
        }
      end)

    ids = MapSet.new(scaled, & &1.id)

    %{
      nodes: Enum.sort_by(scaled, & &1.id),
      links: links |> Enum.filter(fn {a, b} -> a in ids and b in ids end) |> Enum.sort(),
      width: @width,
      height: @height
    }
  end
end
