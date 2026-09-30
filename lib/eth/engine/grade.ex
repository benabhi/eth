defmodule Eth.Engine.Grade do
  @moduledoc """
  Lenguaje del tablón de caza (RF-6.13, RF-7.7). Funciones puras.

  Son **vistas** de métricas que ya existen, nunca métricas nuevas (explicabilidad):

  - **Rango del contrato** según el TVS: `:contract_ranks` (S ≥ 90 · A ≥ 75 · B ≥ 50 ·
    C ≥ 25 · D).
  - **Peligro** según el riesgo de ruta `1 − Certeza de ruta`: `:danger_levels` (bajo,
    moderado, alto, extremo).
  - **Rango del cazador** según la recompensa real acumulada: `:hunter_ranks`, con el
    progreso hacia el siguiente.

  Implementa: RF-6.13, RF-7.7.
  """

  alias Eth.GameRules

  @type danger :: :low | :moderate | :high | :extreme

  @doc "Rango del contrato para un TVS (0–100)."
  @spec rank(number()) :: String.t()
  def rank(tvs) do
    Enum.find_value(GameRules.get(:contract_ranks), "D", fn {letter, min} ->
      if tvs >= min, do: letter
    end)
  end

  @doc "Nivel de peligro para una Certeza de ruta (0–1)."
  @spec danger(number()) :: danger()
  def danger(route_certainty) do
    risk = 1 - route_certainty

    # Tolerancia en el umbral: 1 − 0,95 en float es 0,0500…04 (nunca comparar floats
    # por igualdad).
    Enum.find_value(GameRules.get(:danger_levels), :extreme, fn {level, max} ->
      if risk <= max + 1.0e-9, do: level
    end)
  end

  @doc "Posición de un nivel de peligro (1 bajo … 4 extremo), para barras y orden."
  @spec danger_step(danger()) :: 1..4
  def danger_step(:low), do: 1
  def danger_step(:moderate), do: 2
  def danger_step(:high), do: 3
  def danger_step(:extreme), do: 4

  @doc """
  Rango del cazador por la recompensa real acumulada: `%{rank, next, floor, ceiling,
  progress}` (`next` y `ceiling` son `nil` en el último rango; `progress` entre 0 y 1).
  """
  @spec hunter_rank(number()) :: %{
          rank: String.t(),
          next: String.t() | nil,
          floor: number(),
          ceiling: number() | nil,
          progress: float()
        }
  def hunter_rank(total) do
    ranks = GameRules.get(:hunter_ranks)
    index = ranks |> Enum.take_while(fn {_rank, min} -> total >= min end) |> length() |> max(1)
    {rank, floor} = Enum.at(ranks, index - 1)

    case Enum.at(ranks, index) do
      {next, ceiling} ->
        %{
          rank: rank,
          next: next,
          floor: floor,
          ceiling: ceiling,
          progress: min(max((total - floor) / (ceiling - floor), 0.0), 1.0)
        }

      nil ->
        %{rank: rank, next: nil, floor: floor, ceiling: nil, progress: 1.0}
    end
  end
end
