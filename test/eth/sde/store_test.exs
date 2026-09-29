defmodule Eth.Sde.StoreTest do
  # Estado global: persistent_term, directorio de datos de test y stubs compartidos.
  use Eth.DataCase, async: false

  alias Eth.Esi.Budget
  alias Eth.EsiStub
  alias Eth.Routing
  alias Eth.Sde
  alias Eth.Sde.Store
  alias Eth.SdeFixture
  alias Eth.Storage

  @moduletag :tmp_dir
  @moduletag :capture_log

  setup %{tmp_dir: tmp_dir} do
    Req.Test.set_req_test_to_shared()
    Budget.resume_all()
    File.rm_rf!(Storage.path("sde"))

    on_exit(fn ->
      Req.Test.set_req_test_to_private()
      File.rm_rf!(Storage.path("sde"))

      for key <- [{Eth.Sde, :data}, {Eth.Sde, :meta}, {Eth.Routing, :graph}],
          do: :persistent_term.erase(key)
    end)

    Phoenix.PubSub.subscribe(Eth.PubSub, Sde.topic())
    {:ok, zip: SdeFixture.zip_binary(tmp_dir)}
  end

  defp stub_download(zip) do
    Req.Test.stub(Eth.Sde.Download, fn conn ->
      case conn.request_path do
        "/static-data/tranquility/latest.jsonl" ->
          line =
            Jason.encode!(%{
              "_key" => "sde",
              "buildNumber" => SdeFixture.build(),
              "releaseDate" => "2026-09-28T11:08:09Z"
            })

          Plug.Conn.send_resp(conn, 200, line <> "\n")

        "/static-data/tranquility/eve-online-static-data-3552227-jsonl.zip" ->
          Plug.Conn.send_resp(conn, 200, zip)
      end
    end)
  end

  defp stub_station_names do
    Req.Test.stub(Eth.Esi.Client, fn conn ->
      EsiStub.respond(conn, 200, [
        %{
          "id" => 60_003_760,
          "category" => "station",
          "name" => "Jita IV - Moon 4 - Caldari Navy Assembly Plant"
        }
      ])
    end)
  end

  defp await_ready(origin) do
    assert_receive {:sde_status, %{state: :ready, origin: ^origin} = status}, 10_000
    status
  end

  test "descarga, procesa y publica; el segundo arranque carga desde la caché", %{zip: zip} do
    stub_download(zip)
    stub_station_names()

    start_supervised!(Store)
    status = await_ready(:download)

    assert status.build == SdeFixture.build()
    assert status.routable_systems == 3
    assert Sde.ready?()
    assert Sde.system(30_000_142).name == "Jita"
    assert Sde.station(60_003_760).name == "Jita IV - Moon 4 - Caldari Navy Assembly Plant"
    assert Sde.type(34).packaged_volume == 0.01
    assert {30_000_144, %{name: "Perimeter"}} = Sde.system_by_name("perimeter")

    # Rápida pasa por lowsec; Segura no llega a Ahbazon (0.42).
    assert Routing.distance(30_000_142, 30_005_196, :shortest) == 2
    assert Routing.distance(30_000_142, 30_005_196, :secure) == nil
    assert Routing.path(30_000_142, 30_005_196) == [30_000_142, 30_000_144, 30_005_196]

    # Quedó solo la caché procesada: el zip y los archivos extraídos se borran.
    assert Path.wildcard(Path.join(Storage.path("sde"), "*")) |> Enum.map(&Path.basename/1) ==
             ["processed-#{SdeFixture.build()}.etf"]

    # Segundo arranque: sin red, desde la caché.
    stop_supervised!(Store)
    Req.Test.stub(Eth.Sde.Download, fn _conn -> raise "no debería descargar" end)
    start_supervised!(Store)
    assert await_ready(:cache).systems == 3
  end

  test "sin nombres de ESI, compone el nombre de la estación", %{zip: zip} do
    stub_download(zip)
    Req.Test.stub(Eth.Esi.Client, fn conn -> EsiStub.respond(conn, 503, %{"error" => "down"}) end)

    start_supervised!(Store)
    await_ready(:download)

    assert Sde.station(60_003_760).name == "Jita IV - Moon 4 - Caldari Navy Assembly Plant"
  end

  test "si la descarga falla queda en error sin datos" do
    Req.Test.stub(Eth.Sde.Download, &Plug.Conn.send_resp(&1, 500, "caído"))

    start_supervised!(Store)
    assert_receive {:sde_status, %{state: :error, error: error}}, 5_000
    assert error =~ "500"
    refute Sde.ready?()
    assert Routing.distance(30_000_142, 30_000_144) == nil
  end
end
