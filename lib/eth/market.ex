defmodule Eth.Market do
  @moduledoc """
  API pública del módulo de mercado para la capa web y otros contextos (RNF-7.3).
  La web nunca habla directamente con pollers ni tablas ETS.

  Implementa: RF-8.2, RF-8.3, RF-8.8.
  """

  alias Eth.Market.{RegionManager, RegionPoller}

  # Margen tras Expires para que la descarga del ciclo siguiente termine (The Forge ≈ 25 s).
  @refresh_margin_s 120

  @doc "Fuente de datos de mercado: `:live` (ESI) o `:replay` (snapshots grabados)."
  @spec data_source() :: :live | :replay
  def data_source, do: Application.get_env(:eth, :data_source, :live)

  @doc "Tópico con los cambios de estado de los pollers."
  @spec status_topic() :: String.t()
  defdelegate status_topic, to: RegionPoller, as: :topic

  @doc "Estado de todos los pollers regionales (vacío si el mercado no está corriendo)."
  @spec region_statuses() :: [map()]
  def region_statuses do
    if Process.whereis(RegionManager) do
      RegionManager.regions()
      |> Enum.map(fn {id, _name} -> safe_status(id) end)
      |> Enum.reject(&is_nil/1)
    else
      []
    end
  end

  defp safe_status(region_id) do
    RegionPoller.status(region_id)
  catch
    :exit, _ -> nil
  end

  @doc """
  Frescura de un snapshot (RF-4.9): `:fresh` mientras no venció `Expires` (+ margen para
  la descarga siguiente); después se degrada por antigüedad según `:staleness_minutes`
  (degradado / viejo / excluido). `:none` si no hay datos.
  """
  @spec freshness(DateTime.t() | nil, DateTime.t() | nil, DateTime.t()) ::
          :none | :fresh | :degraded | :stale | :excluded
  def freshness(nil, _expires, _now), do: :none

  def freshness(%DateTime{} = last_modified, expires, %DateTime{} = now) do
    {_fresh, degraded, stale} = Eth.GameRules.get(:staleness_minutes)
    age_min = DateTime.diff(now, last_modified, :second) / 60

    cond do
      expires && DateTime.compare(now, DateTime.add(expires, @refresh_margin_s, :second)) == :lt ->
        :fresh

      age_min <= degraded ->
        :degraded

      age_min <= stale ->
        :stale

      true ->
        :excluded
    end
  end

  @doc "Actualizar ahora (solo si ESI ya tiene datos nuevos o la región está en error)."
  @spec refresh_now(pos_integer()) :: :ok | {:error, atom()}
  defdelegate refresh_now(region_id), to: RegionPoller

  @doc "Pausa manual de una región."
  @spec pause(pos_integer()) :: :ok
  defdelegate pause(region_id), to: RegionPoller

  @doc "Reanuda una región pausada."
  @spec resume(pos_integer()) :: :ok
  defdelegate resume(region_id), to: RegionPoller
end
