defmodule EthWeb.RowChanges do
  @moduledoc """
  Qué filas del tablón cambiaron entre dos actualizaciones (RF-6.3), para resaltarlas un
  momento: las **nuevas** (no estaban en la versión anterior) y las que **mejoraron** o
  **empeoraron** (el valor principal cambió más que `@threshold`).

  Función pura: recibe lo conocido (`%{id => valor}`, o `nil` si no hay que comparar,
  como en la primera carga o al cambiar filtros) y las filas nuevas, y devuelve
  `{resaltados, conocido}` con `resaltados :: %{id => :new | :up | :down}`.

  Implementa: RF-6.3.
  """

  # Cambio relativo mínimo para marcar una fila como mejorada o empeorada.
  @threshold 0.01

  @type kind :: :new | :up | :down
  @type known :: %{optional(term()) => number()} | nil

  @doc "Resaltados de las filas frente a lo conocido, y lo conocido actualizado."
  @spec diff(known(), [map()], (map() -> number())) ::
          {%{term() => kind()}, %{term() => number()}}
  def diff(known, rows, value) do
    current = Map.new(rows, &{&1.id, value.(&1)})
    {changes(known, current), current}
  end

  defp changes(nil, _current), do: %{}

  defp changes(known, current) do
    for {id, now} <- current, kind = kind(Map.fetch(known, id), now), into: %{}, do: {id, kind}
  end

  defp kind(:error, _now), do: :new

  defp kind({:ok, before}, now) do
    cond do
      now > before + abs(before) * @threshold -> :up
      now < before - abs(before) * @threshold -> :down
      true -> nil
    end
  end

  ## Filas expiradas (RF-6.3)

  # Cuántas filas expiradas se muestran a la vez y cuánto quedan antes de salir.
  @max_expired 20
  @expire_ms 1_500

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
  Clase CSS del resaltado (animación que se desvanece sola). `generation` es un
  contador de cargas: alterna entre dos variantes de la animación para que una fila que
  vuelve a cambiar en la carga siguiente se resalte otra vez (con la misma clase el
  navegador no repite la animación).
  """
  @spec class(kind() | nil, non_neg_integer()) :: String.t() | nil
  def class(kind, generation \\ 0)
  def class(nil, _generation), do: nil
  def class(kind, generation) when rem(generation, 2) == 0, do: "eth-flash-#{kind}"
  def class(kind, _generation), do: "eth-flash-#{kind}-alt"
end
