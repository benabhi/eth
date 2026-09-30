defmodule Eth.Threat.SupervisorTest do
  # Cambia `:killfeed` y `:data_source` globales: no async.
  use ExUnit.Case, async: false

  alias Eth.Threat.Supervisor, as: ThreatSupervisor

  setup do
    previous = {Application.get_env(:eth, :killfeed), Application.get_env(:eth, :data_source)}

    on_exit(fn ->
      {killfeed, source} = previous
      Application.put_env(:eth, :killfeed, killfeed)
      Application.put_env(:eth, :data_source, source)
    end)

    :ok
  end

  # Hijos que arrancaría el supervisor, sin arrancarlos (nunca se toca la red).
  defp children do
    {:ok, {_flags, specs}} = ThreatSupervisor.init([])
    Enum.map(specs, & &1.id)
  end

  test "en vivo arranca el radar, la línea base y el feed de R2Z2 (RF-3.1)" do
    Application.put_env(:eth, :data_source, :live)
    Application.put_env(:eth, :killfeed, :r2z2)

    ids = children()
    assert Eth.Threat.Radar in ids
    assert Eth.Threat.Baseline in ids
    assert Eth.Threat.R2Z2 in ids
    refute Eth.Threat.ReplayFeed in ids
  end

  test "con el feed apagado queda el radar sin feed; en Replay, el feed grabado" do
    Application.put_env(:eth, :data_source, :live)
    Application.put_env(:eth, :killfeed, :off)
    ids = children()
    refute Eth.Threat.R2Z2 in ids
    assert Eth.Threat.Radar in ids

    Application.put_env(:eth, :data_source, :replay)
    assert Eth.Threat.ReplayFeed in children()
  end
end
