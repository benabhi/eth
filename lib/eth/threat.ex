defmodule Eth.Threat do
  @moduledoc """
  API pública del radar de amenazas para la web y otros contextos (RNF-7.3): la capa web
  nunca lee las tablas ETS del radar ni habla con sus procesos directamente.

  Implementa: RF-3.8, RF-8.5.
  """

  alias Eth.Threat.{Baseline, KillFeed, Radar}

  @doc "Tópico con los cambios del mapa de calor (`{:heatmap, versión}`)."
  @spec heat_topic() :: String.t()
  defdelegate heat_topic, to: Radar

  @doc "Tópico con las kills relevantes (`{:kill, resumen}`)."
  @spec kills_topic() :: String.t()
  defdelegate kills_topic, to: Radar

  @doc "¿Radar degradado? (sin feed en vivo, RF-3.8)."
  @spec degraded?() :: boolean()
  defdelegate degraded?, to: Radar

  @doc "Sistemas con kills en la ventana, de mayor a menor amenaza."
  @spec hot_systems() :: [map()]
  defdelegate hot_systems, to: Radar

  @doc "Últimas kills relevantes."
  @spec recent_kills() :: [map()]
  defdelegate recent_kills, to: Radar

  @doc "Estado del feed de killmails (fuente, secuencia, atraso)."
  @spec feed_status() :: map()
  defdelegate feed_status, to: KillFeed, as: :status

  @doc "Horas muestreadas y último cálculo de la línea base."
  @spec baseline_meta() :: map()
  defdelegate baseline_meta, to: Baseline, as: :meta
end
