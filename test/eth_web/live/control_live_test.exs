defmodule EthWeb.ControlLiveTest do
  # La pausa global de ESI es estado compartido: no async.
  use EthWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Eth.Esi.Budget
  alias Eth.Events

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

  test "sin mercado corriendo muestra el estado vacío", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/control")

    assert html =~ "Centro de control"
    assert html =~ "Todavía no hay pollers corriendo"
  end

  test "muestra los estados de región que llegan por PubSub y su detalle", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/control")

    send(view.pid, {:region_status, region_status(%{})})
    assert render(view) =~ "The Forge: Cacheado"
    assert render(view) =~ "405k"

    html = view |> element("#region-10000002") |> render_click()
    assert html =~ "404,647"
    assert html =~ "405 (3 × 304)"
    assert html =~ "Actualizar ahora"
  end

  test "refleja descarga con progreso y errores", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/control")

    send(view.pid, {:region_status, region_status(%{status: :fetching, progress: {110, 405}})})
    assert render(view) =~ "Pág 110/405"

    send(
      view.pid,
      {:region_status, region_status(%{status: :backoff, failures: 2, last_error: "HTTP 502"})}
    )

    assert render(view) =~ "The Forge: Error"
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
    {:ok, view, _html} = live(conn, ~p"/control")

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
end
