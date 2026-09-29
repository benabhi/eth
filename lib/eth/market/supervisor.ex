defmodule Eth.Market.Supervisor do
  @moduledoc """
  Supervisor del módulo de mercado (ERS §3.2). `rest_for_one`: si cae el dueño de las
  tablas, se reinician los pollers (sus datos ya no existen); si cae un poller, nada más.
  """
  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [
      Eth.Market.TableOwner,
      {Registry, keys: :unique, name: Eth.Market.Registry},
      {Task.Supervisor, name: Eth.Market.TaskSupervisor},
      {DynamicSupervisor, name: Eth.Market.RegionSupervisor, strategy: :one_for_one},
      Eth.Market.RegionManager
    ]

    # En modo Replay no se guardan snapshots (serían los mismos datos reproducidos).
    children =
      if Eth.Market.data_source() == :live,
        do: children ++ [Eth.Market.SnapshotSaver],
        else: children

    # Al final: con rest_for_one, una caída de precios o historial no reinicia a los pollers.
    Supervisor.init(children ++ [Eth.Market.Prices, Eth.Market.History],
      strategy: :rest_for_one
    )
  end
end
