defmodule Eth.Tracking.Supervisor do
  @moduledoc """
  Supervisor de los viajes (ERS §3.2): registro y supervisor dinámico de los
  `Eth.Tracking.RunMonitor`, tareas y, al arrancar, la restauración de los viajes activos o
  cerrados sin reconciliar. Arranca después de las sesiones de personajes.
  """
  use Supervisor

  alias Eth.Tracking
  alias Eth.Tracking.RunMonitor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: Eth.Tracking.Registry},
      {Task.Supervisor, name: Eth.Tracking.TaskSupervisor},
      {DynamicSupervisor, name: Eth.Tracking.RunSupervisor, strategy: :one_for_one},
      {Task, &restore/0}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp restore, do: Enum.each(Tracking.to_monitor(), &RunMonitor.start/1)
end
