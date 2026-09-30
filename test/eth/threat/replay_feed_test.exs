defmodule Eth.Threat.ReplayFeedTest do
  use Eth.DataCase, async: false

  alias Eth.{EngineFixture, KillmailFixture}
  alias Eth.Threat.{KillFeed, Killmail, Radar, ReplayFeed}

  @moduletag :tmp_dir
  @moduletag :capture_log

  setup %{tmp_dir: tmp_dir} do
    :ok = EngineFixture.load_sde(tmp_dir)
    File.rm_rf!(Path.join(Eth.Storage.data_dir(), "threat"))
    File.rm_rf!(Path.join(Eth.Storage.data_dir(), "replay"))
    start_supervised!({Task.Supervisor, name: Eth.Threat.TaskSupervisor})
    start_supervised!(Radar)
    Phoenix.PubSub.subscribe(Eth.PubSub, Radar.kills_topic())
    on_exit(fn -> File.rm_rf!(Path.join(Eth.Storage.data_dir(), "replay")) end)
    :ok
  end

  defp record(kills) do
    path = Radar.kills_file("replay")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(Enum.map(kills, &Killmail.to_json/1)))
  end

  defp kill(opts) do
    {:ok, kill} = opts |> KillmailFixture.raw() |> Killmail.normalize()
    kill
  end

  test "reproduce las kills grabadas con la hora corrida al presente (RF-1.11)" do
    old = ~U[2026-09-01 10:00:00Z]

    record([
      %{kill(system_id: 30_000_142, location_id: 1) | time: old},
      %{kill(system_id: 30_005_196) | time: DateTime.add(old, 60)}
    ])

    start_supervised!(ReplayFeed)
    assert %{source: :replay, status: :live, recorded: 2, loops: 0} = ReplayFeed.status()

    # La primera kill llega con su antigüedad relativa (60 s antes que la más nueva),
    # ya corrida al presente: el radar la ve dentro de la ventana.
    assert_receive {:kill, %{system_id: 30_000_142, time: time}}, 3_000
    assert_in_delta DateTime.diff(DateTime.utc_now(), time), 60, 5
    assert %{last_kill_at: %DateTime{}} = ReplayFeed.status()
  end

  test "sin grabación el feed queda vacío y no entrega kills" do
    start_supervised!(ReplayFeed)
    assert %{source: :replay, status: :empty, recorded: 0} = ReplayFeed.status()
    refute_receive {:kill, _}, 300
  end

  test "el adaptador elige la implementación según la fuente y el ajuste" do
    previous = Application.get_env(:eth, :killfeed)
    on_exit(fn -> Application.put_env(:eth, :killfeed, previous) end)

    Application.put_env(:eth, :killfeed, :off)
    assert KillFeed.impl() == nil
    assert KillFeed.status() == %{source: :off}

    Application.put_env(:eth, :killfeed, :r2z2)
    assert KillFeed.impl() == Eth.Threat.R2Z2
    # Sin el proceso corriendo, el estado es "apagado" (nunca falla).
    assert KillFeed.status() == %{source: :off}
  end
end
