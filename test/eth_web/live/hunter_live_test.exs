defmodule EthWeb.HunterLiveTest do
  use EthWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Eth.Engine.Coordinator
  alias Eth.EngineFixture, as: F
  alias Eth.Market.{History, HistoryStats, TableOwner}

  @moduletag :tmp_dir
  @moduletag :capture_log

  @tritanium 34

  setup %{tmp_dir: tmp_dir} do
    :ok = F.load_sde(tmp_dir)
    start_supervised!(TableOwner)
    start_supervised!({Task.Supervisor, name: Eth.Engine.TaskSupervisor})
    start_supervised!(Coordinator)
    Phoenix.PubSub.subscribe(Eth.PubSub, Coordinator.topic())
    :ok
  end

  # Tritanium barato en Jita 4-4 y comprado caro en una estructura de Perimeter (1 salto).
  defp publish_market(buy_price \\ 5.0) do
    F.publish_orders([
      {:sell, @tritanium, 4.0, 10_000_000, F.jita_44(), F.jita(), []},
      {:buy, @tritanium, buy_price, 10_000_000, F.perimeter_station(), F.perimeter(), []}
    ])

    assert_receive {:opportunities_updated, _meta}, 5_000
  end

  test "sin evaluación todavía muestra el estado de espera", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#hunter-status", "todavía no evaluó")
    assert has_element?(view, "#opportunities-empty")
  end

  test "lista las oportunidades del motor con su cálculo", %{conn: conn} do
    publish_market()
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#opportunities tr[id^='opp-']", "Tritanium")
    assert has_element?(view, "#hunter-status", "1 oportunidades")
    # Bodega por defecto 38.500 m³: 3.850.000 unidades de 0,01 m³.
    assert has_element?(view, "#opportunities", "3,850,000")
  end

  test "los filtros viajan en la URL y filtran", %{conn: conn} do
    publish_market()
    {:ok, view, _html} = live(conn, ~p"/")

    view |> form("#filters", filters: %{search: "amarr"}) |> render_change()
    assert_patch(view, ~p"/?search=amarr")
    refute has_element?(view, "#opportunities tr[id^='opp-']")

    # La URL restaura la vista.
    {:ok, view, _html} = live(conn, ~p"/?search=perimeter&cargo_m3=100&min_profit=1k")
    assert has_element?(view, "#opportunities tr[id^='opp-']", "10,000")
  end

  test "el detalle explica el cálculo y ofrece Multibuy", %{conn: conn} do
    publish_market()
    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("#opportunities tr[id^='opp-']") |> render_click()
    assert has_element?(view, "#detail", "Libro consumido")
    assert has_element?(view, "#detail", "¿Por qué TVS")
    assert has_element?(view, "#copy-detail[data-text='Tritanium\t3850000']")
  end

  test "congelar acumula cambios pendientes hasta aplicarlos", %{conn: conn} do
    publish_market()
    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("#freeze") |> render_click()
    publish_market(6.0)
    assert render(view) =~ "1 cambio pendiente"

    view |> element("#freeze") |> render_click()
    refute render(view) =~ "cambio pendiente"
  end

  describe "anti-scam (RF-4.8)" do
    setup do
      start_supervised!(History)

      # Historial estable a 4,5 en The Forge: una compra a 50 es 11× la mediana.
      as_of = HistoryStats.last_day(DateTime.utc_now())

      stats =
        0..29
        |> Enum.map(
          &%{"date" => Date.to_iso8601(Date.add(as_of, -&1)), "average" => 4.5, "volume" => 1_000}
        )
        |> HistoryStats.compute(as_of)

      :ets.insert(:eth_history_stats, {{10_000_002, @tritanium}, stats})
      :ok
    end

    test "una SCAM se oculta por defecto y, si se muestra, tiene las acciones bloqueadas",
         %{conn: conn} do
      publish_market(50.0)
      {:ok, view, _html} = live(conn, ~p"/")
      refute has_element?(view, "#opportunities tr[id^='opp-']")

      {:ok, view, _html} = live(conn, ~p"/?shield=all")
      assert has_element?(view, "#opportunities", "☠ SCAM")

      view |> element("#opportunities tr[id^='opp-']") |> render_click()
      assert has_element?(view, "#shield-alert", "SCAM ALERT")
      assert has_element?(view, "#shield-alert", "Compra a 11,1× la mediana de 7 días")
      assert has_element?(view, "#copy-detail[disabled]")
      assert has_element?(view, "#set-route[disabled]")
      refute has_element?(view, "#copy-detail[data-text]")

      view |> element("#report-false-positive") |> render_click()
      assert render(view) =~ "Falso positivo registrado"

      assert [%{opportunity_snapshot: %{"status" => "scam"}}] =
               Eth.Repo.all(Eth.Engine.ScamReport)
    end

    test "una oportunidad legítima muestra su historial", %{conn: conn} do
      publish_market(4.8)
      {:ok, view, _html} = live(conn, ~p"/?min_profit=1k")

      view |> element("#opportunities tr[id^='opp-']") |> render_click()
      refute has_element?(view, "#shield-alert")
      assert has_element?(view, "#history svg polyline")
      assert has_element?(view, "#history", "30 / 30")
    end
  end
end
