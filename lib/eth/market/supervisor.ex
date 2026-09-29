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

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
