defmodule Eth.Market.SnapshotSaver do
  @moduledoc """
  Guarda los snapshots vigentes en disco cada `:snapshot_save_interval_ms` y al apagar
  la aplicación de forma ordenada (RF-1.10, RNF-2.8).

  Arranca después de `TableOwner` en el supervisor del mercado, así en el apagado
  termina antes que él y las tablas todavía existen cuando guarda.
  """
  use GenServer

  require Logger

  alias Eth.{Events, GameRules}
  alias Eth.Market.{RegionManager, Snapshots}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    # Tiempo suficiente para escribir todos los snapshots al apagar.
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, shutdown: 60_000}
  end

  @doc "Guarda ahora todos los snapshots vigentes."
  @spec save_now() :: non_neg_integer()
  def save_now, do: GenServer.call(__MODULE__, :save, 60_000)

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    schedule()
    {:ok, nil}
  end

  @impl true
  def handle_call(:save, _from, state), do: {:reply, save(), state}

  @impl true
  def handle_info(:save, state) do
    save()
    schedule()
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, _state) do
    count = save()
    Logger.info("Snapshots guardados al apagar: #{count}")
  end

  defp save do
    names = Map.new(RegionManager.regions())
    Snapshots.save_all(names, Snapshots.dir(:snapshots))
  rescue
    error ->
      Events.emit(
        :warning,
        "Mercado",
        "No se pudieron guardar los snapshots: #{Exception.message(error)}"
      )

      0
  catch
    :exit, _ -> 0
  end

  defp schedule, do: Process.send_after(self(), :save, GameRules.get(:snapshot_save_interval_ms))
end
