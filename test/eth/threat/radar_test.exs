defmodule Eth.Threat.RadarTest do
  use Eth.DataCase, async: false

  alias Eth.{AppState, EngineFixture, KillmailFixture}
  alias Eth.Threat.{Killmail, R2Z2, Radar}

  @moduletag :tmp_dir
  @moduletag :capture_log

  @ahbazon 30_005_196

  setup %{tmp_dir: tmp_dir} do
    :ok = EngineFixture.load_sde(tmp_dir)
    File.rm_rf!(Path.join(Eth.Storage.data_dir(), "threat"))
    start_supervised!({Task.Supervisor, name: Eth.Threat.TaskSupervisor})
    :ok
  end

  defp kill(opts) do
    {:ok, kill} = opts |> KillmailFixture.raw() |> Killmail.normalize()
    kill
  end

  describe "radar" do
    setup do
      start_supervised!(Radar)
      Phoenix.PubSub.subscribe(Eth.PubSub, Radar.heat_topic())
      Phoenix.PubSub.subscribe(Eth.PubSub, Radar.kills_topic())
      :ok
    end

    test "una kill aislada no alerta; tres en un gate con atacantes repetidos sí" do
      Radar.ingest(kill(system_id: 30_000_142, location_id: 1, attackers: [{7, 22_456, 22_456}]))
      assert_receive {:kill, %{gate_to: "Perimeter"}}, 1_000
      refute_receive {:heatmap, _}, 100
      assert %{kills: 1, alert: false, threat: threat} = Radar.system(30_000_142)
      assert threat == 0.0

      for char <- [8, 9] do
        Radar.ingest(
          kill(
            system_id: 30_000_142,
            location_id: 1,
            attackers: [{7, 22_456, 22_456}, {char, 4_310, 4_310}]
          )
        )
      end

      assert_receive {:heatmap, 1}, 1_000

      assert %{alert: true, threat: threat, classification: %{type: :gate_camp}} =
               Radar.system(30_000_142)

      assert threat >= 0.3
      assert [%{system_id: 30_000_142} | _] = Radar.hot_systems()
      assert length(Radar.recent_kills()) == 3
    end

    test "una kill en un gate con víctima que no es de transporte también es relevante" do
      Radar.ingest(kill(system_id: 30_000_142, location_id: 1, victim_type: 670))
      assert_receive {:kill, %{gate_to: "Perimeter", victim_transport: false}}, 1_000
    end

    test "descarta kills fuera de la ventana" do
      Radar.ingest(kill(system_id: @ahbazon, time: DateTime.add(DateTime.utc_now(), -3_600)))
      Radar.recent_kills()
      assert Radar.system(@ahbazon) == nil
    end

    test "sin kills del feed durante 2 min el radar queda degradado" do
      refute Radar.degraded?()
      # Con el feed apagado (ETH_KILLFEED=off) el radar está degradado desde el arranque.
      Application.put_env(:eth, :killfeed, :off)
      on_exit(fn -> Application.delete_env(:eth, :killfeed) end)
      send(Process.whereis(Radar), :tick)
      Radar.recent_kills()
      assert Radar.degraded?()
    end

    test "guarda las kills de la ventana y las restaura al reiniciar" do
      Radar.ingest(kill(system_id: @ahbazon))
      Radar.recent_kills()
      stop_supervised!(Radar)

      start_supervised!(Radar)
      assert %{kills: 1} = Radar.system(@ahbazon)
    end
  end

  describe "feed R2Z2 (RF-3.1)" do
    setup do
      Req.Test.set_req_test_to_shared()
      on_exit(&Req.Test.set_req_test_to_private/0)
      start_supervised!(Radar)
      :ok
    end

    test "arranca en la última secuencia, procesa kills, espera tras un 404 y guarda el cursor" do
      test_pid = self()

      Req.Test.stub(R2Z2, fn conn ->
        send(test_pid, {:r2z2, conn.request_path, Map.new(conn.req_headers)["user-agent"]})

        case conn.request_path do
          "/ephemeral/sequence.json" ->
            Req.Test.json(conn, %{"sequence" => 100})

          "/ephemeral/100.json" ->
            Req.Test.json(conn, KillmailFixture.raw(id: 1, sequence: 100, system_id: @ahbazon))

          "/ephemeral/101.json" ->
            Plug.Conn.send_resp(conn, 404, "")
        end
      end)

      start_supervised!(R2Z2)
      assert_receive {:r2z2, "/ephemeral/sequence.json", user_agent}, 1_000
      assert user_agent =~ "EVETradeHunter/"
      assert_receive {:r2z2, "/ephemeral/100.json", _}, 1_000
      assert_receive {:r2z2, "/ephemeral/101.json", _}, 1_000
      # Después de un 404 espera 6 s antes de reintentar la misma secuencia.
      refute_receive {:r2z2, _, _}, 500

      assert %{status: :waiting, sequence: 101, processed: 1} = R2Z2.status()
      assert %{kills: 1} = Radar.system(@ahbazon)

      stop_supervised!(R2Z2)
      assert %{"sequence" => 100} = AppState.get("r2z2_cursor")
    end

    test "continúa desde el cursor guardado si tiene menos de 24 h" do
      AppState.put("r2z2_cursor", %{
        "sequence" => 500,
        "at" => DateTime.to_iso8601(DateTime.utc_now())
      })

      test_pid = self()

      Req.Test.stub(R2Z2, fn conn ->
        send(test_pid, {:r2z2, conn.request_path})
        Plug.Conn.send_resp(conn, 404, "")
      end)

      start_supervised!(R2Z2)
      assert_receive {:r2z2, "/ephemeral/501.json"}, 1_000
    end

    test "un 403 detiene el feed una hora" do
      Req.Test.stub(R2Z2, &Plug.Conn.send_resp(&1, 403, ""))
      start_supervised!(R2Z2)

      wait_until(fn -> R2Z2.status().status == :banned end)
      assert %DateTime{} = R2Z2.status().banned_until
    end
  end

  test "las kills se serializan a JSON y vuelven iguales" do
    k = kill(system_id: @ahbazon, location_id: 3)

    assert k |> Killmail.to_json() |> Jason.encode!() |> Jason.decode!() |> Killmail.from_json() ==
             k
  end

  defp wait_until(fun, tries \\ 50) do
    cond do
      fun.() ->
        :ok

      tries == 0 ->
        flunk("la condición no se cumplió a tiempo")

      true ->
        Process.sleep(20)
        wait_until(fun, tries - 1)
    end
  end
end
