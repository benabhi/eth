defmodule Eth.Market.RegionPollerTest do
  use ExUnit.Case, async: false

  alias Eth.Esi.Budget
  alias Eth.EsiStub
  alias Eth.Market.{RegionPoller, TableOwner}

  @region 10_000_002

  setup do
    Req.Test.set_req_test_to_shared()
    on_exit(&Req.Test.set_req_test_to_private/0)
    :ets.delete_all_objects(:eth_esi_budget)
    Budget.resume_all()

    start_supervised!(TableOwner)
    start_supervised!({Registry, keys: :unique, name: Eth.Market.Registry})
    start_supervised!({Task.Supervisor, name: Eth.Market.TaskSupervisor})
    Phoenix.PubSub.subscribe(Eth.PubSub, RegionPoller.topic())
    :ok
  end

  defp stub_ok(expires) do
    Req.Test.stub(Eth.Esi.Client, fn conn ->
      EsiStub.respond(
        conn,
        200,
        [
          %{
            "order_id" => 1,
            "type_id" => 34,
            "is_buy_order" => false,
            "price" => 5.0,
            "location_id" => 60_003_760,
            "system_id" => 30_000_142,
            "volume_remain" => 10,
            "volume_total" => 10,
            "min_volume" => 1,
            "range" => "region",
            "issued" => "2026-09-28T12:00:00Z",
            "duration" => 90
          }
        ],
        pages: 1,
        last_modified: DateTime.utc_now(),
        expires: expires,
        etag: ~s("x"),
        rate_limit: {"market-order", 11_000}
      )
    end)
  end

  defp start_poller do
    pid = start_supervised!({RegionPoller, {@region, "The Forge"}})
    send(pid, :tick)
    pid
  end

  defp await_status(status) do
    assert_receive {:region_status, %{status: ^status} = s}, 2_000
    s
  end

  @tag :capture_log
  test "descarga, publica y programa el próximo ciclo según Expires" do
    # Las fechas HTTP tienen resolución de segundos.
    expires = DateTime.utc_now() |> DateTime.add(300, :second) |> DateTime.truncate(:second)
    stub_ok(expires)
    start_poller()

    status = await_status(:cached)
    assert status.orders == 1
    assert status.generation == 1
    assert status.tier == :hub
    assert DateTime.compare(status.next_at, expires) != :lt
    assert TableOwner.current({:region, @region})
  end

  @tag :capture_log
  test "no permite actualizar antes de Expires; sí después" do
    stub_ok(DateTime.add(DateTime.utc_now(), 300, :second))
    start_poller()
    await_status(:cached)

    assert RegionPoller.refresh_now(@region) == {:error, :not_expired}

    stub_ok(DateTime.add(DateTime.utc_now(), -1, :second))
    send(GenServer.whereis({:via, Registry, {Eth.Market.Registry, @region}}), :tick)
    await_status(:cached)
    assert RegionPoller.refresh_now(@region) == :ok
  end

  @tag :capture_log
  test "un error pasa a backoff y registra el fallo" do
    Req.Test.stub(Eth.Esi.Client, fn conn -> EsiStub.respond(conn, 502, %{"error" => "bad"}) end)
    start_poller()

    status = await_status(:backoff)
    assert status.failures == 1
    assert status.last_error == "HTTP 502"
  end

  @tag :capture_log
  test "la pausa manual detiene el ciclo; reanudar respeta Expires" do
    expires = DateTime.utc_now() |> DateTime.add(300, :second) |> DateTime.truncate(:second)
    stub_ok(expires)
    start_poller()
    await_status(:cached)

    :ok = RegionPoller.pause(@region)
    assert %{status: :paused, pause_reason: :manual, next_at: nil} = RegionPoller.status(@region)
    assert RegionPoller.refresh_now(@region) == {:error, :paused}

    :ok = RegionPoller.resume(@region)
    status = RegionPoller.status(@region)
    assert status.status == :idle
    # No se adelanta a Expires aunque se reanude antes.
    assert DateTime.compare(status.next_at, expires) != :lt
  end

  @tag :capture_log
  test "en backoff se puede forzar el reintento (ignorar backoff)" do
    Req.Test.stub(Eth.Esi.Client, fn conn -> EsiStub.respond(conn, 502, %{"error" => "bad"}) end)
    start_poller()
    await_status(:backoff)

    assert RegionPoller.refresh_now(@region) == :ok
  end

  test "el backoff crece exponencialmente y abre el circuito" do
    assert RegionPoller.backoff_ms(1) in 40..60
    assert RegionPoller.backoff_ms(3) in 160..240
    assert RegionPoller.backoff_ms(5) == 600_000
  end
end
