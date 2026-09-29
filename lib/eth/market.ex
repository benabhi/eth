defmodule Eth.Market do
  @moduledoc """
  API pública del módulo de mercado para la capa web y otros contextos (RNF-7.3).
  La web nunca habla directamente con pollers ni tablas ETS.

  Implementa: RF-1.6, RF-8.2, RF-8.3, RF-8.8, RF-9.6.
  """

  alias Eth.Market.{History, RegionManager, RegionPoller, Structure, StructureManager, Structures}

  # Margen tras Expires para que la descarga del ciclo siguiente termine (The Forge ≈ 25 s).
  @refresh_margin_s 120

  @doc "Fuente de datos de mercado: `:live` (ESI) o `:replay` (snapshots grabados)."
  @spec data_source() :: :live | :replay
  def data_source, do: Application.get_env(:eth, :data_source, :live)

  @doc "Tópico con los cambios de estado de los pollers."
  @spec status_topic() :: String.t()
  defdelegate status_topic, to: RegionPoller, as: :topic

  @doc "Tópico con los anuncios de estadísticas de historial nuevas (RF-1.12)."
  @spec history_topic() :: String.t()
  defdelegate history_topic, to: History, as: :topic

  @doc "Estado de la cola de historial (vacío si el proceso no corre)."
  @spec history_status() :: map() | nil
  def history_status do
    if Process.whereis(History), do: History.status()
  catch
    :exit, _ -> nil
  end

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

  ## Estructuras (RF-1.6, RF-9.6)

  @doc """
  Estructuras registradas con su estado: `%{structure, selected, access}` donde `access`
  es `%{character_id => "ok" | "forbidden" | "unknown"}`.
  """
  @spec structures() :: [map()]
  def structures do
    selected = MapSet.new(Structures.selection(), & &1.id)
    access = Structures.access_map()

    for s <- Structures.list() do
      %{
        structure: s,
        selected: MapSet.member?(selected, s.id),
        access: for({{sid, cid}, a} <- access, sid == s.id, into: %{}, do: {cid, a.status})
      }
    end
  end

  @doc "Sigue una estructura por ID (privada o pública) y pide un ciclo."
  @spec follow_structure(pos_integer()) :: :ok
  def follow_structure(id) do
    {:ok, _} = Structures.follow(id)
    Eth.Events.emit(:action, "Usuario", "Estructura #{id} agregada a las seguidas")
    StructureManager.refresh()
  end

  @doc "Cambia si se sigue una estructura y su override de broker fee (proporción)."
  @spec update_structure(pos_integer(), map()) :: :ok | {:error, term()}
  def update_structure(id, attrs) do
    with %Structure{} = s <- Structures.get(id) || {:error, :not_found},
         {:ok, _} <- Structures.update_settings(s, attrs) do
      StructureManager.refresh()
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
