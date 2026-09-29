defmodule Eth.Threat.ReplayFeed do
  @moduledoc """
  Feed de killmails del modo Replay (RF-1.11): reproduce en bucle, sin red, las kills
  grabadas con `mix eth.replay.record` (`priv/data/replay/kills.json`).

  Cada kill se entrega con la hora corrida al presente, conservando su antigüedad
  relativa, así el radar la ve dentro de la ventana. Sin grabación, el feed queda vacío
  y el radar se degrada a la línea base, como en vivo.

  Implementa: RF-1.11, RF-3.1.
  """
  use GenServer

  @behaviour Eth.Threat.KillFeed

  alias Eth.Clock
  alias Eth.Threat.{Killmail, Radar}

  @interval_ms 2_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl Eth.Threat.KillFeed
  def status, do: GenServer.call(__MODULE__, :status)

  @impl true
  def init(_opts) do
    kills = load()
    if kills != [], do: Process.send_after(self(), :next, @interval_ms)
    {:ok, %{kills: kills, index: 0, loops: 0, last_kill_at: nil}}
  end

  @impl true
  def handle_call(:status, _from, state) do
    reply = %{
      source: :replay,
      status: if(state.kills == [], do: :empty, else: :live),
      recorded: length(state.kills),
      loops: state.loops,
      last_kill_at: state.last_kill_at
    }

    {:reply, reply, state}
  end

  @impl true
  def handle_info(:next, state) do
    {kill, offset_s} = Enum.at(state.kills, state.index)
    now = Clock.utc_now()
    Radar.ingest(%{kill | time: DateTime.add(now, -offset_s)})

    next = rem(state.index + 1, length(state.kills))
    loops = if next == 0, do: state.loops + 1, else: state.loops
    Process.send_after(self(), :next, @interval_ms)
    {:noreply, %{state | index: next, loops: loops, last_kill_at: now}}
  end

  # Kills grabadas con su antigüedad relativa a la más reciente (en segundos).
  # sobelow_skip ["Traversal.FileModule"]
  defp load do
    with {:ok, json} <- File.read(Radar.kills_file("replay")),
         {:ok, list} when is_list(list) <- Jason.decode(json),
         kills when kills != [] <-
           list |> Enum.map(&Killmail.from_json/1) |> Enum.reject(&is_nil/1) do
      newest = kills |> Enum.map(& &1.time) |> Enum.max(DateTime)

      kills
      |> Enum.sort_by(& &1.time, DateTime)
      |> Enum.map(&{&1, DateTime.diff(newest, &1.time)})
    else
      _ -> []
    end
  end
end
