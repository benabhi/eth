defmodule Eth.Engine.SkillGains do
  @moduledoc """
  Cuánto ganaría el piloto con más nivel en una habilidad de comercio (RF-6.15). Función
  pura.

  No repite fórmulas: vuelve a personalizar el contrato con la habilidad subida un nivel
  y al V, con la misma función que usa el tablón (`value_fun`), y resta el valor actual.
  Así cuenta todo lo que la habilidad cambia en el cálculo (impuestos, comisiones,
  cantidad que deja margen) y nada más.

  Habilidades que modela el motor:

  - **Accounting**: baja el sales tax (las tres familias).
  - **Broker Relations**: baja el broker fee al publicar órdenes (Estación y Por órdenes;
    en una estructura con broker propio no cambia nada).

  Implementa: RF-6.15.
  """

  @type skill :: :accounting | :broker_relations
  @type step :: %{level: 1..5, gain: float()}
  @type gain :: %{skill: skill(), level: 0..5, next: step() | nil, max: step() | nil}

  @max_level 5

  @doc """
  Ganancia de subir cada habilidad: al nivel siguiente (`next`) y al V (`max`, solo si
  está a más de un nivel). `params` trae el nivel actual de cada habilidad; `value_fun`
  devuelve el valor a comparar (beneficio, beneficio por día) o `nil` si el contrato no
  es viable. Sin valor actual no hay nada que comparar.
  """
  @spec gains(map(), [skill()], (map() -> number() | nil)) :: [gain()]
  def gains(params, skills, value_fun) do
    case value_fun.(params) do
      nil ->
        []

      base ->
        for skill <- skills, level = Map.fetch!(params, skill) do
          %{
            skill: skill,
            level: level,
            next: if(level < @max_level, do: step(params, skill, level + 1, base, value_fun)),
            max: if(level < @max_level - 1, do: step(params, skill, @max_level, base, value_fun))
          }
        end
    end
  end

  defp step(params, skill, level, base, value_fun) do
    case value_fun.(Map.put(params, skill, level)) do
      nil -> nil
      value -> %{level: level, gain: value - base}
    end
  end
end
