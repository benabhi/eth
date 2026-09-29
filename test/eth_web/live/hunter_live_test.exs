defmodule EthWeb.HunterLiveTest do
  use EthWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Eth.Engine.Coordinator
  alias Eth.EngineFixture, as: F
  alias Eth.Market.TableOwner

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
end
