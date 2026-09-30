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

  @doc "Clase CSS del resaltado (animación que se desvanece sola)."
  @spec class(kind() | nil) :: String.t() | nil
  def class(:new), do: "eth-flash-new"
  def class(:up), do: "eth-flash-up"
  def class(:down), do: "eth-flash-down"
  def class(nil), do: nil
end
