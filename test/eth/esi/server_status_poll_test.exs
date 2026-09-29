defmodule Eth.Esi.ServerStatusPollTest do
  use Eth.DataCase, async: false

  alias Eth.Esi.{Budget, ServerStatus}
  alias Eth.EsiStub

  @moduletag :capture_log

  setup do
    Req.Test.set_req_test_to_shared()
    Budget.resume_all()
    on_exit(&Req.Test.set_req_test_to_private/0)
    Phoenix.PubSub.subscribe(Eth.PubSub, ServerStatus.topic())
    :ok
  end

  test "consulta /status y publica el estado de Tranquility" do
    Req.Test.stub(Eth.Esi.Client, fn conn ->
      EsiStub.respond(conn, 200, %{
        "players" => 19_138,
        "server_version" => "3552227",
        "start_time" => "2026-09-28T11:05:11Z",
        "vip" => false
      })
    end)

    start_supervised!(ServerStatus)

    assert_receive {:server_status, %{online: true, players: 19_138, vip: false}}, 2_000
    assert %{online: true, server_version: "3552227"} = ServerStatus.current()
    refute ServerStatus.downtime?()
  end

  test "si ESI no responde, queda sin conexión" do
    Req.Test.stub(Eth.Esi.Client, fn conn -> EsiStub.respond(conn, 503, %{"error" => "down"}) end)

    start_supervised!(ServerStatus)

    assert_receive {:server_status, %{online: false}}, 2_000
  end

  test "VIP cuenta como downtime" do
    Req.Test.stub(Eth.Esi.Client, fn conn ->
      EsiStub.respond(conn, 200, %{"players" => 0, "vip" => true})
    end)

    start_supervised!(ServerStatus)
    assert_receive {:server_status, %{vip: true}}, 2_000
    assert ServerStatus.downtime?()
  end
end
