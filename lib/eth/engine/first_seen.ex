defmodule Eth.Engine.FirstSeen do
  @moduledoc """
  Antigüedad de cada oportunidad en el tablón (RF-6.14): desde cuándo aparece en las
  evaluaciones del motor sin interrupción. Función pura.

  El coordinador guarda, por familia, `%{id => unix}` de la evaluación anterior: una
  oportunidad que sigue conserva su momento de aparición; una nueva (o una que había
  desaparecido y vuelve) toma el de esta evaluación. Se guarda como segundos unix (no
  `DateTime`) para que el mapa de decenas de miles de IDs ocupe poco.

  Se pierde al reiniciar: lo que ya estaba en la primera evaluación se muestra como
  "al menos" desde el arranque (`seen_since` en los metadatos del motor).

  Implementa: RF-6.14.
  """

  @typedoc "Momento de aparición por ID (segundos unix)."
  @type seen :: %{optional(String.t()) => integer()}

  @doc """
  Pone `first_seen` en cada oportunidad con lo conocido (o `now` si es nueva) y devuelve
  el mapa de las vigentes, sin las que ya no están.
  """
  @spec stamp([struct], seen(), integer()) :: {[struct], seen()} when struct: map()
  def stamp(items, previous, now) do
    Enum.map_reduce(items, %{}, fn item, acc ->
      first = Map.get(previous, item.id, now)
      {%{item | first_seen: first}, Map.put(acc, item.id, first)}
    end)
  end

  @doc """
  Minutos que lleva la oportunidad en el tablón y si es una cota inferior (estaba ya en
  la primera evaluación desde el arranque, `since`).
  """
  @spec age(integer() | nil, integer() | nil, DateTime.t()) ::
          {non_neg_integer(), boolean()} | nil
  def age(nil, _since, _now), do: nil

  def age(first_seen, since, now) do
    minutes = max(DateTime.to_unix(now) - first_seen, 0) |> div(60)
    {minutes, since != nil and first_seen <= since}
  end
end
