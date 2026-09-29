defmodule Eth.Market.Policy do
  @moduledoc """
  Política de frecuencia por nivel de región según el presupuesto disponible
  (RF-1.2, ERS §8.11). Funciones puras.

  | Presupuesto restante | N1 Hubs | N2 Activas | N3 Resto |
  |---|---|---|---|
  | ≥ 40 %   | cada ciclo | cada ciclo     | cada ciclo     |
  | 20–40 %  | cada ciclo | cada ciclo     | cada 2 ciclos  |
  | 10–20 %  | cada ciclo | cada 2 ciclos  | cada 3 ciclos  |
  | < 10 %   | cada ciclo | en pausa       | en pausa       |
  """

  alias Eth.GameRules

  @type tier :: :hub | :active | :rest

  @doc "Nivel de una región: hub fijo por configuración; activa según páginas del último ciclo."
  @spec tier(pos_integer(), non_neg_integer() | nil) :: tier()
  def tier(region_id, last_pages) do
    cond do
      region_id in GameRules.get(:hub_region_ids) -> :hub
      (last_pages || 0) >= GameRules.get(:active_region_min_pages) -> :active
      true -> :rest
    end
  end

  @doc "Cada cuántos ciclos debe descargarse un nivel (`:paused` = no descargar)."
  @spec every(tier(), float()) :: pos_integer() | :paused
  def every(:hub, _ratio), do: 1
  def every(_tier, ratio) when ratio >= 0.4, do: 1
  def every(:active, ratio) when ratio >= 0.2, do: 1
  def every(:rest, ratio) when ratio >= 0.2, do: 2
  def every(:active, ratio) when ratio >= 0.1, do: 2
  def every(:rest, ratio) when ratio >= 0.1, do: 3
  def every(_tier, _ratio), do: :paused

  @doc "¿Toca descargar en este ciclo? `skipped` = ciclos salteados seguidos."
  @spec fetch?(tier(), float(), non_neg_integer()) :: boolean()
  def fetch?(tier, ratio, skipped) do
    case every(tier, ratio) do
      :paused -> false
      n -> skipped + 1 >= n
    end
  end
end
