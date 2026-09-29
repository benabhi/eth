defmodule Eth.Threat.KillFeed do
  @moduledoc """
  Adaptador intercambiable del feed de killmails en vivo (RF-3.1). Cada implementación
  es un proceso que entrega las kills normalizadas a `Eth.Threat.Radar.ingest/1` e
  informa su estado.

  Implementaciones: `Eth.Threat.R2Z2` (por defecto), `Eth.Threat.ReplayFeed` (modo
  Replay, sin red) y `:off`. `ETH_KILLFEED` elige entre `r2z2` y `off`.

  Implementa: RF-3.1, RF-1.11.
  """

  @doc "Estado público del feed (fuente, secuencia, último dato, errores)."
  @callback status() :: map()

  @doc "Módulo de la implementación activa (`nil` si el feed está apagado)."
  @spec impl() :: module() | nil
  def impl do
    cond do
      Eth.Market.data_source() == :replay -> Eth.Threat.ReplayFeed
      Application.get_env(:eth, :killfeed, :r2z2) == :off -> nil
      true -> Eth.Threat.R2Z2
    end
  end

  @doc "Estado del feed activo (`%{source: :off}` si está apagado o no corre)."
  @spec status() :: map()
  def status do
    case impl() do
      nil -> %{source: :off}
      module -> if Process.whereis(module), do: module.status(), else: %{source: :off}
    end
  catch
    :exit, _ -> %{source: :off}
  end
end
