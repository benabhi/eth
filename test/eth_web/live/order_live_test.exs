defmodule EthWeb.OrderLiveTest do
  use EthWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Eth.Engine.Coordinator
  alias Eth.EngineFixture, as: F
  alias Eth.Market.{History, HistoryStats, TableOwner}
  alias EthWeb.OrderParams

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

  # Listado: Tritanium barato en Perimeter y venta en Jita 4-4, con historial del hub.
  defp publish_market do
    as_of = HistoryStats.last_day(DateTime.utc_now())

    stats =
      0..29
      |> Enum.map(
        &%{
          "date" => Date.to_iso8601(Date.add(as_of, -&1)),
          "average" => 5.0,
          "volume" => 2_000_000
        }
      )
      |> HistoryStats.compute(as_of)

    :ets.insert(:eth_history_stats, {{10_000_002, @tritanium}, stats})

    F.publish_orders([
      {:sell, @tritanium, 5.5, 1_000_000, F.jita_44(), F.jita(), []},
      {:sell, @tritanium, 4.0, 2_000_000, F.perimeter_npc(), F.perimeter(), []}
    ])

    assert_receive {:opportunities_updated, _meta}, 5_000
  end

  test "lista el Listado con su precio sugerido y el detalle paso a paso", %{conn: conn} do
    publish_market()
    {:ok, view, _html} = live(conn, ~p"/orders")

    assert has_element?(view, "#family-orders[aria-current='page']")
    assert has_element?(view, "#order-rows [id^='ord-'] > [data-head]", "Listado")

    view |> element("#order-rows [id^='ord-'] > [data-head]") |> render_click()
    assert has_element?(view, "#orders-detail", "Publicá una orden de venta")
    assert has_element?(view, "#copy-order-price[data-text='5.49']")
  end

  test "el filtro de modo viaja en la URL", %{conn: conn} do
    publish_market()
    {:ok, view, _html} = live(conn, ~p"/orders")

    view |> form("#orders-filters", filters: %{mode: "buy_order"}) |> render_change()
    assert_patch(view, ~p"/orders?mode=buy_order")
    refute has_element?(view, "#order-rows [id^='ord-'] > [data-head]")
  end

  test "parámetros: modos, rutas y listas cerradas" do
    q = OrderParams.to_query(%{"mode" => "listing", "route_mode" => "evasive", "max_days" => "3"})
    assert q.mode == :listing
    assert q.route_mode == :secure
    assert q.max_days == 3
    assert OrderParams.to_query(%{"mode" => "otro"}).mode == nil
  end
end
