defmodule Eth.Market.RegionManagerTest do
  use Eth.DataCase, async: false

  alias Eth.Esi.Budget
  alias Eth.EsiStub
  alias Eth.Market.{RegionManager, RegionPoller, Snapshots, SnapshotSaver, TableOwner}

  @moduletag :capture_log

  setup do
    Req.Test.set_req_test_to_shared()
    Budget.resume_all()
    File.rm_rf!(Eth.Storage.data_dir())

    on_exit(fn ->
      Req.Test.set_req_test_to_private()
      Application.put_env(:eth, :data_source, :live)
      File.rm_rf!(Eth.Storage.data_dir())
    end)

    start_supervised!(TableOwner)
    start_supervised!({Registry, keys: :unique, name: Eth.Market.Registry})
    start_supervised!({Task.Supervisor, name: Eth.Market.TaskSupervisor})

    start_supervised!(
      {DynamicSupervisor, name: Eth.Market.RegionSupervisor, strategy: :one_for_one}
    )

    :ok
  end

  defp stub_universe do
    Req.Test.stub(Eth.Esi.Client, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/universe/regions"} ->
          # Incluye J-space, abisal, Pochven y el Mercado Global de PLEX: se excluyen.
          EsiStub.respond(conn, 200, [
            10_000_002,
            11_000_001,
            12_000_001,
            10_000_070,
            19_000_001,
            10_000_043
          ])

        {"POST", "/universe/names"} ->
          respond_names(conn)
      end
    end)
  end

  defp respond_names(conn) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    names = %{10_000_002 => "The Forge", 10_000_043 => "Domain"}
    ids = Jason.decode!(body)

    EsiStub.respond(
      conn,
      200,
      Enum.map(ids, &%{"id" => &1, "name" => names[&1], "category" => "region"})
    )
  end

  defp publish_sample(region_id) do
    tid = :ets.new(:eth_orders, [:ordered_set, :public])
    :ets.insert(tid, {{34, :sell, 5.0, 1}, 60_003_760, 30_000_142, 10, 1, :region, 0, 5.0, 1})
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    meta = %{
      last_modified: now,
      expires: DateTime.add(now, 300, :second),
      pages: 1,
      page_etags: %{},
      orders: 1
    }

    {:ok, _gen} = TableOwner.publish(tid, {:region, region_id}, meta)
  end

  test "descubre las regiones escaneables y arranca un poller por región" do
    stub_universe()
    start_supervised!(RegionManager)

    assert RegionManager.regions() == [{10_000_043, "Domain"}, {10_000_002, "The Forge"}]
    assert %{active: 2} = DynamicSupervisor.count_children(Eth.Market.RegionSupervisor)
    assert %{name: "The Forge", status: :idle} = RegionPoller.status(10_000_002)
  end

  test "sin ESI no arranca pollers y reintenta más tarde" do
    Req.Test.stub(Eth.Esi.Client, fn conn -> EsiStub.respond(conn, 503, %{"error" => "down"}) end)
    start_supervised!(RegionManager)

    assert RegionManager.regions() == []
    assert %{active: 0} = DynamicSupervisor.count_children(Eth.Market.RegionSupervisor)
  end

  test "SnapshotSaver guarda los snapshots vigentes con el nombre de la región" do
    stub_universe()
    start_supervised!(RegionManager)
    publish_sample(10_000_002)

    start_supervised!(SnapshotSaver)
    assert SnapshotSaver.save_now() == 1
    assert Snapshots.list(Snapshots.dir(:snapshots)) == [{10_000_002, "The Forge"}]
  end

  test "en modo Replay las regiones y los ciclos salen de los snapshots grabados" do
    publish_sample(10_000_002)
    entry = TableOwner.current({:region, 10_000_002})
    :ok = Snapshots.save(10_000_002, "The Forge", entry, Snapshots.dir(:replay))

    Application.put_env(:eth, :data_source, :replay)
    Req.Test.stub(Eth.Esi.Client, fn _conn -> raise "el modo Replay no debe llamar a ESI" end)
    Phoenix.PubSub.subscribe(Eth.PubSub, RegionPoller.topic())

    start_supervised!(RegionManager)
    assert RegionManager.regions() == [{10_000_002, "The Forge"}]

    pid = GenServer.whereis({:via, Registry, {Eth.Market.Registry, 10_000_002}})
    send(pid, :tick)

    assert_receive {:region_status, %{status: :cached, replay: true, orders: 1, generation: 2}},
                   2_000
  end
end
