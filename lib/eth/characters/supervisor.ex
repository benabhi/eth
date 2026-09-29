defmodule Eth.Characters.Supervisor do
  @moduledoc """
  Supervisor de sesiones de personajes (ERS §3.2). Al arrancar levanta una sesión por
  cada personaje vinculado con token vigente.
  """
  use Supervisor

  alias Eth.Characters
  alias Eth.Characters.Sessions

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: Eth.Characters.Registry},
      {DynamicSupervisor, name: Eth.Characters.SessionSupervisor, strategy: :one_for_one},
      {Task, &start_sessions/0}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp start_sessions do
    for %{token_status: "ok", id: id} <- Characters.list(),
        do: Sessions.start(id)
  end
end
