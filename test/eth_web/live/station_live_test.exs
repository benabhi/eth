defmodule EthWeb.StationLiveTest do
  use EthWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Eth.Engine.Coordinator
  alias Eth.EngineFixture, as: F
  alias Eth.Market.{History, HistoryStats, TableOwner}
  alias EthWeb.StationParams

  @moduletag :tmp_dir
  @moduletag :capture_log

  @tritanium 34

  setup %{tmp_dir: tmp_dir} do
    :ok = F.load_sde(tmp_dir)
    start_supervised!(TableOwner)
    start_supervised!(History)
    start_supervised!({Task.Supervisor, name: Eth.Engine.TaskSupervisor})
    start_supervised!(Coordinator)
    Phoenix.PubSub.subscribe(Eth.PubSub, Coordinator.topic())
    :ok
  end

  # Libro de Tritanium en Jita 4-4 con diferencial e historial estable.
  defp publish_station_market do
    as_of = HistoryStats.last_day(DateTime.utc_now())

    stats =
      0..29
      |> Enum.map(
        &%{
          "date" => Date.to_iso8601(Date.add(as_of, -&1)),
          "average" => 4.5,
          "volume" => 1_000_000
        }
      )
      |> HistoryStats.compute(as_of)

    :ets.insert(:eth_history_stats, {{10_000_002, @tritanium}, stats})

    F.publish_orders([
      {:buy, @tritanium, 4.0, 1_000_000, F.jita_44(), F.jita(), []},
      {:sell, @tritanium, 5.0, 1_000_000, F.jita_44(), F.jita(), []}
    ])

    assert_receive {:opportunities_updated, _meta}, 5_000
  end

  test "el selector de familia lleva de Directo a Estación conservando la búsqueda", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/?search=trit")
    assert has_element?(view, "#family-direct[aria-current='page']")
    assert has_element?(view, "#family-station[href='/station?search=trit']")
    assert has_element?(view, "#family-orders")
  end

  test "lista el station trading con precios sugeridos y el detalle", %{conn: conn} do
    publish_station_market()
    {:ok, view, _html} = live(conn, ~p"/station")

    assert has_element?(view, "#family-station[aria-current='page']")
    assert has_element?(view, "#station-rows tr[id^='st-']", "Tritanium")

    view |> element("#station-rows tr[id^='st-']") |> render_click()
    assert has_element?(view, "#station-detail", "Tritanium")
    assert has_element?(view, "#copy-buy-price[data-text='4.01']")
    assert has_element?(view, "#copy-sell-price[data-text='4.99']")
  end

  test "los filtros viajan en la URL", %{conn: conn} do
    publish_station_market()
    {:ok, view, _html} = live(conn, ~p"/station")

    view |> form("#station-filters", filters: %{min_margin: "90"}) |> render_change()
    assert_patch(view, ~p"/station?min_margin=90")
    refute has_element?(view, "#station-rows tr[id^='st-']")
  end

  test "parámetros: porcentajes, hubs válidos y listas cerradas" do
    q =
      StationParams.to_query(%{"min_margin" => "7,5", "location_id" => "60003760", "sort" => "x"})

    assert_in_delta q.min_margin, 0.075, 1.0e-12
    assert q.location_id == 60_003_760
    assert q.sort == :score

    # Un ID que no es un hub configurado se ignora.
    assert StationParams.to_query(%{"location_id" => "123"}).location_id == nil
  end
end
