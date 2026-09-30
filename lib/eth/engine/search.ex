defmodule Eth.Engine.Search do
  @moduledoc """
  Búsqueda de texto del tablón (RF-6.4): sin mayúsculas ni acentos, por contenido.

  El texto buscable de cada oportunidad (objeto, estaciones, sistemas y regiones) se arma
  **una vez** al publicar la evaluación y queda guardado en la oportunidad
  (`search_text`): normalizar siete campos por oportunidad en cada tecla costaba ~150 ms
  por consulta con el universo completo (RNF-1.1). Funciones puras.

  Implementa: RF-6.4, RNF-1.1.
  """

  # Separador entre campos: una búsqueda nunca debería calzar "cruzando" dos campos.
  @separator "\n"

  @doc "Texto sin mayúsculas, sin acentos y sin espacios en los extremos."
  @spec normalize(String.t()) :: String.t()
  def normalize(text) do
    text
    |> String.downcase()
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/\p{Mn}/u, "")
    |> String.trim()
  end

  @doc "Texto buscable a partir de sus campos (los `nil` se ignoran)."
  @spec text([String.t() | nil]) :: String.t()
  def text(fields) do
    fields
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join(@separator, &normalize/1)
  end

  @doc """
  Guarda el texto buscable en cada elemento de una lista normalizando cada cadena
  distinta **una sola vez**: en una evaluación los mismos nombres de objetos, estaciones y
  regiones se repiten miles de veces (36 mil candidatos de estación con pocos miles de
  nombres). `fields` da los campos de un elemento y `put` guarda el texto.
  """
  @spec index([item], (item -> [String.t() | nil]), (item, String.t() -> item)) :: [item]
        when item: term()
  def index(items, fields, put) do
    {items, _cache} =
      Enum.map_reduce(items, %{}, fn item, cache ->
        {parts, cache} =
          item
          |> fields.()
          |> Enum.reject(&is_nil/1)
          |> Enum.map_reduce(cache, &cached_normalize/2)

        {put.(item, Enum.join(parts, @separator)), cache}
      end)

    items
  end

  defp cached_normalize(field, cache) do
    case cache do
      %{^field => normalized} ->
        {normalized, cache}

      _ ->
        normalized = normalize(field)
        {normalized, Map.put(cache, field, normalized)}
    end
  end

  @doc "¿El texto buscable contiene la búsqueda ya normalizada? (`\"\"` calza todo)."
  @spec matches?(String.t(), String.t()) :: boolean()
  def matches?(_text, ""), do: true
  def matches?(text, search), do: String.contains?(text, search)
end
