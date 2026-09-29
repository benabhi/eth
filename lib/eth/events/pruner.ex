defmodule Eth.Events.Pruner do
  @moduledoc """
  Aplica la retención del registro de eventos (7 días) cada 6 horas (RF-8.7).
  """
  use GenServer

  @interval :timer.hours(6)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    send(self(), :prune)
    {:ok, nil}
  end

  @impl true
  def handle_info(:prune, state) do
    Eth.Events.prune()
    Process.send_after(self(), :prune, @interval)
    {:noreply, state}
  end
end
