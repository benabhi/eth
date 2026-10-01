defmodule EthWeb.ControlLiveTest do
  # La pausa global de ESI es estado compartido: no async.
  use EthWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Eth.{EngineFixture, Events, KillmailFixture}
  alias Eth.Esi.Budget
  alias Eth.Threat.{Killmail, Radar}
  alias EthWeb.ControlLive

  setup do
    Budget.resume_all()
    :ok
  end

  defp region_status(attrs) do
    now = DateTime.utc_now()

    Map.merge(
      %{
        region_id: 10_000_002,
        name: "The Forge",
        tier: :hub,
        status: :cached,
        pause_reason: nil,
        next_at: DateTime.add(now, 100, :second),
        progress: nil,
        failures: 0,
        last_error: nil,
        history: [%{at: now, duration_ms: 22_000, pages: 405, not_modified: 3}],
        generation: 2,
        orders: 404_647,
        sell_orders: 276_000,
        buy_orders: 128_647,
        pages: 405,
        bytes: 77_700_000,
        last_modified: DateTime.add(now, -60, :second),
        expires: DateTime.add(now, 240, :second),
        not_modified_pages: 3
      },
      attrs
    )
  end

  test "muestra las métricas de la última hora (RF-8.9)", %{conn: conn} do
    start_supervised!(Eth.Metrics)

    :telemetry.execute([:eth, :esi, :request], %{duration_ms: 120}, %{
      path: "/x",
      status: 200,
      group: nil,
      not_modified: false
    })

    {:ok, view, _html} = live(conn, ~p"/control")
    # Los contadores muestran el último minuto completo; el de ahora recién empieza.
    assert has_element?(view, "#metric-requests", "0")
    assert has_element?(view, "#metric-latency", "120 ms")
    assert has_element?(view, "#spark-requests polyline")
    assert has_element?(view, "#metric-evaluate", "—")
  end

  test "Requiere atención agrupa las regiones con el mismo problema en un solo aviso", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/control")

    for {id, name} <- [{10_000_002, "The Forge"}, {10_000_043, "Domain"}] do
      send(
        view.pid,
        {:region_status, region_status(%{region_id: id, name: name, status: :backoff})}
      )
    end

    assert has_element?(view, "#attention", "2 regiones · error")
    refute has_element?(view, "#attention", "The Forge: Error")
  end

  test "el pipeline muestra cada etapa y cuenta las pantallas conectadas (RF-8.4)", %{
    conn: conn
  } do
    start_supervised!(Eth.Metrics)
    {:ok, view, _html} = live(conn, ~p"/control")
    _ = :sys.get_state(Eth.Metrics)
    send(view.pid, :tick)

    for stage <- ~w(esi snapshots engine opportunities viewers),
        do: assert(has_element?(view, "#pipe-#{stage}"))

    assert has_element?(view, "#pipe-viewers", "Pestañas abiertas")
    assert has_element?(view, "#pipe-viewers", "1")
  end

  test "sin mercado corriendo muestra el estado vacío", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/control")

    assert html =~ "Centro de control"
    assert html =~ "Todavía no hay pollers corriendo"
  end

  test "muestra los estados de región que llegan por PubSub y su detalle", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/control/market")

    send(view.pid, {:region_status, region_status(%{})})
    assert render(view) =~ "The Forge: Cacheado"
    assert render(view) =~ "405k"

    html = view |> element("#region-10000002") |> render_click()
    assert html =~ "404,647"
    assert html =~ "405 (3 × 304)"
    assert html =~ "Actualizar ahora"
  end

  test "refleja descarga con progreso y errores", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/control/market")

    send(view.pid, {:region_status, region_status(%{status: :fetching, progress: {110, 405}})})
    assert render(view) =~ "Pág 110/405"

    send(
      view.pid,
      {:region_status, region_status(%{status: :backoff, failures: 2, last_error: "HTTP 502"})}
    )

    assert render(view) =~ "The Forge: Error"
  end

  test "el anillo de páginas va vacío al iniciar una descarga, no con el ciclo anterior" do
    starting = region_status(%{status: :fetching, progress: {0, nil}})
    halfway = region_status(%{status: :fetching, progress: {81, 405}})

    assert ControlLive.pages_fraction(starting) == 0.0
    assert_in_delta ControlLive.pages_fraction(halfway), 0.2, 1.0e-9
    assert ControlLive.pages_fraction(region_status(%{})) == 1.0
  end

  test "muestra el estado del SDE", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/control")

    send(view.pid, {:sde_status, %{state: :ready, build: 3_552_227, routable_systems: 5227}})
    assert view |> element("#sde-status") |> render() =~ "5,227"
    assert view |> element("#sde-status") |> render() =~ "3552227"

    send(view.pid, {:sde_status, %{state: :error, error: "sin red"}})
    assert view |> element("#sde-status") |> render() =~ "sin red"
  end

  test "los eventos llegan en vivo y se filtran", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/control/logs")

    Events.emit(:error, "Domain", "timeout de prueba")
    assert render(view) =~ "timeout de prueba"

    html = view |> element("button", "Acciones") |> render_click()
    refute html =~ "timeout de prueba"
  end

  @tag :capture_log
  test "pausa y reanudación global de ESI", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/control")

    view |> element("button", "Pausa global") |> render_click()
    assert {:error, {:paused, _}} = Budget.check()
    assert render(view) =~ "En pausa"

    view |> element("button", "Reanudar") |> render_click()
    assert Budget.check() == :ok
  end

  test "muestra el estado de la cola de historial (RF-1.12)", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/control")
    assert has_element?(view, "#history-status", "—")

    start_supervised!({Task.Supervisor, name: Eth.Market.TaskSupervisor})
    start_supervised!(Eth.Market.History)
    {:ok, view, _html} = live(conn, ~p"/control")
    assert has_element?(view, "#history-status", "0/250")
    assert has_element?(view, "#history-status", "0 en caché · 0 en cola")
  end

  describe "pestañas (RF-8.10)" do
    test "cada pestaña tiene su URL y la barra de salud siempre está visible", %{conn: conn} do
      for tab <- ~w(market radar characters logs esi) do
        {:ok, view, _html} = live(conn, "/control/#{tab}")
        assert has_element?(view, "#control-tabs-#{tab}[aria-current='page']")
        assert has_element?(view, "#health #sde-status")
      end
    end

    test "una pestaña desconocida vuelve al resumen", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/control"}}} = live(conn, "/control/nope")
    end

    test "el resumen lista lo que requiere atención y enlaza a la región", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/control")
      assert has_element?(view, "#attention", "Radar degradado")

      send(
        view.pid,
        {:region_status, region_status(%{status: :backoff, failures: 2, last_error: "HTTP 502"})}
      )

      assert has_element?(view, "#attention", "The Forge: Error")
      assert has_element?(view, "#poller-10000002")

      view |> element("#poller-10000002") |> render_click()
      assert_patch(view, ~p"/control/market?region=10000002")
      assert has_element?(view, "#region-detail", "HTTP 502")
    end
  end

  describe "radar (RF-8.5, RF-3.8)" do
    test "sin radar en vivo muestra el indicador de degradado en la cabecera", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/control/radar")
      assert has_element?(view, "#radar-degraded", "Radar degradado")
      assert has_element?(view, "#radar-hot", "Sin kills PvP")
    end

    @tag :tmp_dir
    test "muestra sistemas calientes y kills relevantes en vivo", %{conn: conn, tmp_dir: tmp_dir} do
      :ok = EngineFixture.load_sde(tmp_dir)
      start_supervised!(Radar)
      {:ok, view, _html} = live(conn, ~p"/control/radar")

      {:ok, kill} =
        KillmailFixture.raw(system_id: 30_005_196, value: 2.5e9)
        |> Killmail.normalize()

      Radar.ingest(kill)
      Radar.recent_kills()
      send(view.pid, :tick)

      assert has_element?(view, "#hot-30005196")
      assert has_element?(view, "#hot-30005196-series rect")
      assert has_element?(view, "#kill-#{kill.id}", "transporte")
      refute has_element?(view, "#radar-degraded")
    end
  end
end
