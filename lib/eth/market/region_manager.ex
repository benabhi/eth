defmodule Eth.Market.RegionManager do
  @moduledoc """
  Descubre las regiones a escanear y arranca un `RegionPoller` por cada una (RF-1.2).

  Obtiene los IDs de `/universe/regions`, filtra las no escaneables
  (`Eth.GameRules.scannable_region?/1`: J-space, abisales, Pochven, PLEX global y el
  subconjunto `ETH_REGIONS`) y resuelve los nombres con `/universe/names`. Si ESI no
  responde, reintenta cada 30 s.

  Implementa: RF-1.2.
  """
  use GenServer

  alias Eth.{Esi, Events, GameRules}
  alias Eth.Market.{RegionPoller, Snapshots}

  @retry_ms 30_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Regiones en escaneo como `[{region_id, nombre}]`, ordenadas por nombre."
  @spec regions() :: [{pos_integer(), String.t()}]
  def regions, do: GenServer.call(__MODULE__, :regions)

  @impl true
  def init(_opts), do: {:ok, %{regions: []}, {:continue, :load}}

  @impl true
  def handle_continue(:load, state), do: {:noreply, load(state)}

  @impl true
  def handle_info(:load, state), do: {:noreply, load(state)}

  @impl true
  def handle_call(:regions, _from, state), do: {:reply, state.regions, state}

  defp load(state) do
    case discover() do
      {:ok, regions} ->
        Enum.each(regions, fn region ->
          DynamicSupervisor.start_child(Eth.Market.RegionSupervisor, {RegionPoller, region})
        end)

        Events.emit(:info, "Mercado", "#{length(regions)} regiones en escaneo")
        %{state | regions: regions}

      {:error, reason} ->
        Events.emit(
          :warning,
          "Mercado",
          "No se pudo obtener la lista de regiones: #{inspect(reason)}"
        )

        Process.send_after(self(), :load, @retry_ms)
        state
    end
  end

  # En modo Replay las regiones son las grabadas; no se consulta ESI.
  defp discover do
    if Eth.Market.data_source() == :replay, do: discover_replay(), else: discover_live()
  end

  defp discover_replay do
    case Snapshots.list(Snapshots.dir(:replay)) do
      [] -> {:error, "modo Replay sin datos: grabá con `mix eth.replay.record`"}
      regions -> {:ok, Enum.filter(regions, fn {id, _} -> GameRules.scannable_region?(id) end)}
    end
  end

  defp discover_live do
    with {:ok, %{body: ids}} <- Esi.region_ids(),
         scannable = Enum.filter(ids, &GameRules.scannable_region?/1),
         {:ok, %{body: names}} <- Esi.names(scannable) do
      regions =
        names
        |> Enum.map(&{&1["id"], &1["name"]})
        |> Enum.sort_by(&elem(&1, 1))

      {:ok, regions}
    end
  end
end
