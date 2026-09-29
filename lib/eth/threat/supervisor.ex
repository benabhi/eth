defmodule Eth.Threat.Supervisor do
  @moduledoc """
  Supervisor del radar de amenazas (ERS §3.2): tareas, línea base, mapa de calor y el
  feed de killmails activo (`Eth.Threat.KillFeed.impl/0`). El feed arranca después del
  radar, que es quien recibe sus kills.
  """
  use Supervisor

  alias Eth.Threat.KillFeed

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children =
      [
        {Task.Supervisor, name: Eth.Threat.TaskSupervisor},
        Eth.Threat.Baseline,
        Eth.Threat.Radar
      ] ++ List.wrap(KillFeed.impl())

    Supervisor.init(children, strategy: :one_for_one)
  end
end
