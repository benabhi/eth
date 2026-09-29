defmodule Eth.Engine.Supervisor do
  @moduledoc "Supervisor del motor de evaluación (ERS §3.2)."
  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [
      {Task.Supervisor, name: Eth.Engine.TaskSupervisor},
      Eth.Engine.Coordinator
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
