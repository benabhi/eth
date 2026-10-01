defmodule EthWeb.RowChanges do
  @moduledoc """
  Qué filas del tablón cambiaron entre dos actualizaciones (RF-6.3), para resaltarlas un
  momento: las **nuevas** (no estaban en la versión anterior) y las que **mejoraron** o
  **empeoraron** (el valor principal cambió más que `@threshold`).

  Función pura: recibe lo conocido (`%{id => valor}`, o `nil` si no hay que comparar,
  como en la primera carga o al cambiar filtros) y las filas nuevas, y devuelve
  `{resaltados, conocido}` con `resaltados :: %{id => :new | :up | :down}`.

  El tablón se recarga seguido (motor, historial, radar), a veces cada uno o dos
  segundos. Para que un resaltado o una fila tachada se vean completos, duran por tiempo
  y no por recarga: `highlights/4` y `with_lingering/4` los conservan entre recargas hasta
  que vence su plazo (antes se recalculaban de cero y se cortaban en la recarga
  siguiente).

  Implementa: RF-6.3.
  """

  # Cambio relativo mínimo para marcar una fila como mejorada o empeorada.
  @threshold 0.01
  # Puntos de TVS o de Certeza (%) que tiene que moverse el puntaje para resaltar la fila.
  @score_step 2

  @type kind :: :new | :up | :down
  @typedoc "Valor principal, o `{valor, puntaje}` para comparar también el puntaje."
  @type value :: number() | {number(), number()}
  @type known :: %{optional(term()) => value()} | nil

  @doc "Resaltados de las filas frente a lo conocido, y lo conocido actualizado."
  @spec diff(known(), [map()], (map() -> value())) ::
          {%{term() => kind()}, %{term() => value()}}
  def diff(known, rows, value) do
    current = Map.new(rows, &{&1.id, value.(&1)})
    {changes(known, current), current}
  end

  defp changes(nil, _current), do: %{}

  defp changes(known, current) do
    for {id, now} <- current, kind = kind(Map.fetch(known, id), now), into: %{}, do: {id, kind}
  end

  defp kind(:error, _now), do: :new

  # Con `{valor, puntaje}` (beneficio y TVS o Certeza %): manda el valor si cambió más del
  # umbral; si no, el puntaje si se movió al menos `@score_step` puntos. Así se ve por qué
  # una fila cambia de posición aunque el beneficio sea el mismo (historial o radar nuevos).
  defp kind({:ok, {before, before_score}}, {now, now_score}) do
    case kind({:ok, before}, now) do
      nil when now_score - before_score >= @score_step -> :up
      nil when before_score - now_score >= @score_step -> :down
      kind -> kind
    end
  end

  defp kind({:ok, before}, now) do
    cond do
      now > before + abs(before) * @threshold -> :up
      now < before - abs(before) * @threshold -> :down
      true -> nil
    end
  end

  ## Filas expiradas (RF-6.3)

  # Cuántas filas expiradas se muestran a la vez y cuánto quedan antes de salir. Las
  # duraciones coinciden con las animaciones de `assets/css/app.css` (`eth-flash-*`,
  # `eth-row-expired`).
  @max_expired 20
  @expire_ms 4_000
  @flash_ms %{new: 4_000, up: 4_000, down: 4_000, moved: 2_500}

  @typedoc "Lo que se recuerda de cada fila para mostrarla tachada: `%{id => {índice, fantasma}}`."
  @type ghosts :: %{optional(term()) => {non_neg_integer(), map()}}

  @doc "Tiempo (ms) que una fila expirada queda tachada antes de salir."
  @spec expire_ms() :: pos_integer()
  def expire_ms, do: @expire_ms

  @doc """
  Fantasmas de las filas: su posición y lo mínimo para dibujarlas tachadas (`ghost`
  devuelve un mapa chico, nunca la fila completa).
  """
  @spec ghosts([map()], (map() -> map())) :: ghosts()
  def ghosts(rows, ghost) do
    rows |> Enum.with_index() |> Map.new(fn {row, i} -> {row.id, {i, ghost.(row)}} end)
  end

  @doc """
  Las filas nuevas con las que desaparecieron intercaladas en su posición anterior,
  marcadas con `expired: true` (a lo sumo #{@max_expired}), y sus IDs para sacarlas
  después de `expire_ms/0`. Con `nil` (primera carga, filtros nuevos) no agrega nada.
  """
  @spec with_expired([map()], ghosts() | nil) :: {[map()], [term()]}
  def with_expired(rows, nil), do: {rows, []}

  def with_expired(rows, previous) do
    current = MapSet.new(rows, & &1.id)

    expired =
      previous
      |> Enum.reject(fn {id, _} -> MapSet.member?(current, id) end)
      |> Enum.sort_by(fn {_id, {index, _ghost}} -> index end)
      |> Enum.take(@max_expired)

    shown =
      Enum.reduce(expired, rows, fn {id, {index, ghost}}, acc ->
        List.insert_at(acc, min(index, length(acc)), Map.merge(ghost, %{id: id, expired: true}))
      end)

    {shown, Enum.map(expired, &elem(&1, 0))}
  end

  @doc """
  Suma a los resaltados las filas que cambiaron su orden frente a las demás sin otro
  cambio (`:moved`, destello neutro): muestra el reordenamiento por cambios chicos de
  puntaje. Las filas solo corridas porque otra entró o salió no se marcan. `previous` son los fantasmas de la carga
  anterior (`ghosts/2`, traen la posición); con `nil` no hace nada.
  """
  @spec with_moved(%{term() => kind()}, ghosts() | nil, [map()]) :: %{term() => kind() | :moved}
  def with_moved(flashes, nil, _rows), do: flashes

  def with_moved(flashes, previous, rows) do
    # Orden relativo entre las filas que estaban y siguen: una fila corrida por otra que
    # entró o salió conserva su orden y no se marca; una que pasó a otra (o fue pasada),
    # sí, aunque sea un solo lugar.
    common = rows |> Enum.map(& &1.id) |> Enum.filter(&Map.has_key?(previous, &1))
    set = MapSet.new(common)

    before_rank =
      previous
      |> Enum.filter(fn {id, _} -> MapSet.member?(set, id) end)
      |> Enum.sort_by(fn {_id, {index, _ghost}} -> index end)
      |> Enum.with_index()
      |> Map.new(fn {{id, _}, rank} -> {id, rank} end)

    # Las que forman la secuencia más larga que conservó su orden no se movieron: se
    # marcan solo las demás (si una fila salta, solo ella; no las que pasó).
    kept = common |> Enum.map(&before_rank[&1]) |> longest_increasing() |> MapSet.new()

    Enum.reduce(common, flashes, fn id, acc ->
      if Map.has_key?(acc, id) or MapSet.member?(kept, before_rank[id]),
        do: acc,
        else: Map.put(acc, id, :moved)
    end)
  end

  # Paso de la subsecuencia: ¿la fila j (anterior) extiende la cadena que termina en i?
  defp extend(j, {l, p}, i, indexed, len) do
    if indexed[j] < indexed[i] and len[j] + 1 > l, do: {len[j] + 1, j}, else: {l, p}
  end

  # Subsecuencia creciente más larga (valores). O(n²): a lo sumo 200 filas.
  defp longest_increasing([]), do: []

  defp longest_increasing(values) do
    indexed = values |> Enum.with_index() |> Enum.map(fn {v, i} -> {i, v} end) |> Map.new()
    n = map_size(indexed)

    {lengths, prev} =
      Enum.reduce(0..(n - 1), {%{}, %{}}, fn i, {len, prev} ->
        best = Enum.reduce(0..(i - 1)//1, {1, nil}, &extend(&1, &2, i, indexed, len))

        {Map.put(len, i, elem(best, 0)), Map.put(prev, i, elem(best, 1))}
      end)

    {last, _} = Enum.max_by(lengths, fn {_i, l} -> l end)

    Stream.iterate(last, &prev[&1])
    |> Enum.take_while(&(&1 != nil))
    |> Enum.map(&indexed[&1])
  end

  @doc """
  Clase CSS del resaltado (animación que se desvanece sola). `generation` es un
  contador de cargas: alterna entre dos variantes de la animación para que una fila que
  vuelve a cambiar en la carga siguiente se resalte otra vez (con la misma clase el
  navegador no repite la animación).
  """
  @spec class(kind() | :moved | nil, non_neg_integer()) :: String.t() | nil
  def class(kind, generation \\ 0)
  def class(nil, _generation), do: nil
  def class(kind, generation) when rem(generation, 2) == 0, do: "eth-flash-#{kind}"
  def class(kind, _generation), do: "eth-flash-#{kind}-alt"

  ## Resaltados y filas tachadas que duran por tiempo (RF-6.3)

  @typedoc "Resaltado vigente de una fila: `{tipo, clase CSS, vence (ms monotónicos)}`."
  @type highlight :: {kind() | :moved, String.t(), integer()}

  @typedoc "Fila tachada que sigue a la vista: `{índice, fantasma, vence (ms)}`."
  @type lingering :: %{optional(term()) => {non_neg_integer(), map(), integer()}}

  @doc "Tiempo (ms) que dura el resaltado de cada tipo."
  @spec flash_ms(kind() | :moved) :: pos_integer()
  def flash_ms(kind), do: Map.fetch!(@flash_ms, kind)

  @doc """
  Resaltados vigentes después de una recarga: los que siguen en plazo se conservan con su
  clase (la animación no se corta ni se reinicia) y los cambios nuevos se suman. Si una
  fila cambia de tipo, o vuelve a cambiar después de vencer, toma la otra variante de la
  clase (`-alt`) para que el navegador repita la animación. Con `nil` (primera carga,
  filtros nuevos) se empieza de cero.
  """
  @spec highlights(%{term() => highlight()} | nil, %{term() => kind() | :moved}, integer()) ::
          %{term() => highlight()}
  def highlights(previous, flashes, now_ms) do
    previous = previous || %{}
    alive = for {id, {_k, _c, until} = h} <- previous, until > now_ms, into: %{}, do: {id, h}

    Enum.reduce(flashes, alive, fn {id, kind}, acc ->
      case acc do
        # Misma animación en curso: sigue sin reiniciarse.
        %{^id => {^kind, _class, _until}} ->
          acc

        # Un reacomodo no tapa un resaltado más importante que todavía se ve.
        %{^id => _alive} when kind == :moved ->
          acc

        _ ->
          old_class = with {_k, class, _u} <- Map.get(previous, id), do: class
          Map.put(acc, id, {kind, fresh_class(kind, old_class), now_ms + flash_ms(kind)})
      end
    end)
  end

  # La variante que no tenía la fila: si la clase no cambia, el navegador no repite la
  # animación.
  defp fresh_class(kind, old_class) do
    base = "eth-flash-#{kind}"
    if old_class == base, do: base <> "-alt", else: base
  end

  @doc "Clase CSS del resaltado vigente de la fila (`nil` si no tiene)."
  @spec class_of(%{term() => highlight()}, term()) :: String.t() | nil
  def class_of(highlights, id) do
    case Map.get(highlights, id) do
      {_kind, class, _until} -> class
      nil -> nil
    end
  end

  @doc """
  Como `with_expired/2`, pero las filas tachadas siguen a la vista durante `expire_ms/0`
  aunque el tablón se recargue en el medio. `lingering` son las tachadas de la recarga
  anterior; devuelve las filas a mostrar, las tachadas vigentes y las que se tacharon
  recién (para programar su salida). Con `previous` en `nil` (primera carga, filtros
  nuevos) no hay tachadas.
  """
  @spec with_lingering([map()], ghosts() | nil, lingering(), integer()) ::
          {[map()], lingering(), [term()]}
  def with_lingering(rows, nil, _lingering, _now_ms), do: {rows, %{}, []}

  def with_lingering(rows, previous, lingering, now_ms) do
    current = MapSet.new(rows, & &1.id)

    # Siguen tachadas las que no vencieron ni volvieron.
    alive =
      for {id, {_i, _g, until} = entry} <- lingering,
          until > now_ms and not MapSet.member?(current, id),
          into: %{},
          do: {id, entry}

    fresh =
      for {id, {index, ghost}} <- previous,
          not MapSet.member?(current, id) and not Map.has_key?(alive, id),
          into: %{},
          do: {id, {index, ghost, now_ms + @expire_ms}}

    kept =
      alive
      |> Map.merge(fresh)
      |> Enum.sort_by(fn {_id, {index, _ghost, _until}} -> index end)
      |> Enum.take(@max_expired)

    shown =
      Enum.reduce(kept, rows, fn {id, {index, ghost, _until}}, acc ->
        List.insert_at(acc, min(index, length(acc)), Map.merge(ghost, %{id: id, expired: true}))
      end)

    kept = Map.new(kept)
    {shown, kept, kept |> Map.keys() |> Enum.filter(&Map.has_key?(fresh, &1))}
  end
end
