defmodule Eth.GameRules do
  @moduledoc """
  Acceso a las reglas del juego y parámetros calibrables (ERS Anexo B).

  Los valores viven en la configuración (`config :eth, Eth.GameRules`) y nunca como
  literales en el código: CCP los cambia (impuestos, regiones especiales, límites).

  Implementa: RNF-15.1.
  """

  @doc "Devuelve un parámetro; falla si no está configurado (evita defaults silenciosos)."
  @spec get(atom()) :: term()
  def get(key) do
    case Keyword.fetch(config(), key) do
      {:ok, value} -> value
      :error -> raise ArgumentError, "parámetro de Eth.GameRules no configurado: #{inspect(key)}"
    end
  end

  @doc "Devuelve un parámetro opcional con valor por defecto."
  @spec get(atom(), term()) :: term()
  def get(key, default), do: Keyword.get(config(), key, default)

  @doc """
  Indica si una región debe escanearse (RF-1.2): excluye J-space, abisal/especiales,
  Pochven y el Mercado Global de PLEX; respeta el subconjunto `ETH_REGIONS` si existe.
  """
  @spec scannable_region?(pos_integer()) :: boolean()
  def scannable_region?(region_id) do
    region_id < get(:excluded_region_id_from) and
      region_id not in get(:excluded_region_ids) and
      in_subset?(region_id)
  end

  defp in_subset?(region_id) do
    case get(:only_region_ids, nil) do
      nil -> true
      ids -> region_id in ids
    end
  end

  defp config, do: Application.get_env(:eth, __MODULE__, [])
end
