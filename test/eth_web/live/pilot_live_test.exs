defmodule EthWeb.PilotLiveTest do
  use EthWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Eth.Characters
  alias Eth.Characters.{Session, Sessions}
  alias Eth.Engine.Coordinator
  alias Eth.EngineFixture, as: F
  alias Eth.Esi.Budget
  alias Eth.EsiStub
  alias Eth.Market.TableOwner

  @moduletag :tmp_dir
  @moduletag :capture_log

  @id 2_112_345_678
  @tritanium 34

  setup %{tmp_dir: tmp_dir} do
    :ok = F.load_sde(tmp_dir)
    Req.Test.set_req_test_to_shared()
    on_exit(&Req.Test.set_req_test_to_private/0)
    Budget.resume_all()

    start_supervised!(TableOwner)
    start_supervised!({Task.Supervisor, name: Eth.Engine.TaskSupervisor})
    start_supervised!(Coordinator)
    start_supervised!(Characters.Supervisor)
    Phoenix.PubSub.subscribe(Eth.PubSub, Coordinator.topic())
    :ok
  end

  @assets_scope "esi-assets.read_assets.v1"

  defp login(scopes \\ Eth.Sso.scopes()) do
    %{
      character_id: @id,
      name: "Hernan Test",
      owner_hash: "owner-hash-1",
      scopes: scopes,
      access_token: "access-1",
      refresh_token: "refresh-1",
      expires_at: DateTime.add(DateTime.utc_now(), 1199, :second)
    }
  end

  # ESI simulado: el piloto está en Jita 4-4, en línea, con una Iteron Mark V sin perfil,
  # Gallente Hauler V y un Expanded Cargohold II montado.
  # Las acciones de UI se reenvían al test.
  defp stub_esi do
    test = self()

    Req.Test.stub(Eth.Esi.Client, fn conn ->
      case String.split(conn.request_path, "/", trim: true) do
        ["ui" | _] ->
          send(test, {:ui, conn.request_path, Plug.Conn.fetch_query_params(conn).query_params})
          EsiStub.respond(conn, 204, nil)

        ["characters", _id, resource] ->
          EsiStub.respond(conn, 200, character_body(resource),
            expires: DateTime.add(DateTime.utc_now(), 60, :second)
          )
      end
    end)
  end

  defp character_body("online"), do: %{"online" => true}

  defp character_body("location"),
    do: %{"solar_system_id" => F.jita(), "station_id" => F.jita_44()}

  defp character_body("ship"), do: %{"ship_type_id" => 657, "ship_item_id" => 1_001}
  defp character_body("wallet"), do: 2_500_000_000.0

  defp character_body("skills") do
    %{
      "skills" => [
        %{"skill_id" => 16_622, "active_skill_level" => 5},
        %{"skill_id" => 3_340, "active_skill_level" => 5}
      ]
    }
  end

  defp character_body("assets") do
    [
      %{
        "item_id" => 5_000,
        "type_id" => 1_319,
        "location_id" => 1_001,
        "location_flag" => "LoSlot0",
        "location_type" => "item",
        "quantity" => 1,
        "is_singleton" => true
      }
    ]
  end

  defp character_body("standings"), do: []

  # Espera a que la sesión tenga todo el contexto y a que la LiveView lo haya procesado.
  defp await_pilot(view, resources \\ 7, attempts \\ 50) do
    context = Sessions.context(@id)

    cond do
      context && map_size(context.context) == resources ->
        _ = :sys.get_state(view.pid)
        :ok

      attempts == 0 ->
        flunk("la sesión nunca completó el contexto: #{inspect(context)}")

      true ->
        assert_receive {:character, @id, _event, _public}, 1_000
        await_pilot(view, resources, attempts - 1)
    end
  end

  defp logged_in(conn, login \\ login()) do
    stub_esi()
    {:ok, _} = Characters.upsert_login(login)
    :ok = Sessions.start(@id, login)
    Phoenix.PubSub.subscribe(Eth.PubSub, Session.topic(@id))
    init_test_session(conn, character_id: @id)
  end

  defp publish_market(buy_price \\ 5.0) do
    F.publish_orders([
      {:sell, @tritanium, 4.0, 10_000_000, F.jita_44(), F.jita(), []},
      {:buy, @tritanium, buy_price, 10_000_000, F.perimeter_station(), F.perimeter(), []}
    ])

    assert_receive {:opportunities_updated, _meta}, 5_000
  end

  defp select_first_row(view) do
    view |> element("#opportunities tr[id^='opp-']") |> render_click()
  end

  test "en modo invitado ofrece el login y deshabilita las acciones in-game", %{conn: conn} do
    publish_market()
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#login-eve")
    refute has_element?(view, "#pilot-bar")

    select_first_row(view)
    assert has_element?(view, "#set-route[disabled]")
    assert has_element?(view, "#open-market[disabled]")
  end

  test "con piloto muestra retrato, nave, ubicación y personaliza los filtros", %{conn: conn} do
    conn = logged_in(conn)
    {:ok, view, _html} = live(conn, ~p"/")
    await_pilot(view)

    assert has_element?(view, "#pilot-name", "Hernan Test")
    assert has_element?(view, "#character-menu img[src*='/characters/#{@id}/portrait']")
    assert has_element?(view, "#pilot-ship img[src*='/types/657/render']")
    assert has_element?(view, "#pilot-ship", "Iteron Mark V")
    # Bodega calculada: 5.800 × 1,25 (Gallente Hauler V) × 1,275 (expansor) = 9.243,75 m³.
    assert has_element?(view, "#pilot-ship", "9,244")
    assert has_element?(view, "#ship-profile-open", "calculada")
    assert has_element?(view, "#pilot-location", "Jita")
    assert has_element?(view, "#pilot-wallet", "2.50B")

    # Los filtros toman Accounting, capital y bodega del piloto.
    assert has_element?(
             view,
             "#filters select[name='filters[accounting]'] option[selected][value='5']"
           )

    assert has_element?(view, "#filters input[name='filters[capital]'][value='2500M']")
    assert has_element?(view, "#filters input[name='filters[cargo_m3]'][value='9243']")
  end

  test "sin el permiso de assets estima con habilidades y el perfil manual manda", %{
    conn: conn
  } do
    conn = logged_in(conn, login(Eth.Sso.scopes() -- [@assets_scope]))
    {:ok, view, _html} = live(conn, ~p"/")
    await_pilot(view, 6)

    assert has_element?(view, "#pilot-ship", "7,250")
    assert has_element?(view, "#ship-profile-open", "estimada")

    view |> element("#ship-profile-open") |> render_click()
    assert has_element?(view, "#ship-dialog")

    view
    |> form("#ship-profile-form",
      ship_profile: %{cargo_m3: "38500", evasion_class: "industrial", apply_to_hull: "true"}
    )
    |> render_submit()

    _ = :sys.get_state(view.pid)
    refute has_element?(view, "#ship-dialog")
    assert has_element?(view, "#pilot-ship", "38,500")
    assert has_element?(view, "#filters input[name='filters[cargo_m3]'][value='38500']")

    # Guardado como perfil del casco: vale para otras Iteron sin perfil propio.
    assert %{cargo_m3: 38_500.0, ship_item_id: nil} = Characters.ship_profile(9_999, 657)
  end

  test "el Centro de control muestra la sesión del personaje (RF-8.6)", %{conn: conn} do
    conn = logged_in(conn)
    {:ok, view, _html} = live(conn, ~p"/")
    await_pilot(view)

    {:ok, control, _html} = live(conn, ~p"/control")
    assert has_element?(control, "#session-#{@id}", "token vigente")
    assert has_element?(control, "#session-#{@id}-wallet", "hace")
    assert has_element?(control, "#session-#{@id}-assets")
  end

  test "fijar ruta desde el origen pone solo el destino", %{conn: conn} do
    # Margen amplio: con la bodega real de la Iteron (5.800 m³) supera el beneficio mínimo.
    publish_market(10.0)
    conn = logged_in(conn)
    {:ok, view, _html} = live(conn, ~p"/")
    await_pilot(view)

    select_first_row(view)
    refute has_element?(view, "#set-route[disabled]")
    view |> element("#set-route") |> render_click()

    destination = Integer.to_string(F.perimeter_station())

    assert_receive {:ui, "/ui/autopilot/waypoint",
                    %{"destination_id" => ^destination, "clear_other_waypoints" => "true"}},
                   2_000

    refute_receive {:ui, "/ui/autopilot/waypoint", _params}, 100
    assert render_async(view) =~ "Ruta fijada en el juego"

    view |> element("#open-market") |> render_click()
    type_id = Integer.to_string(@tritanium)
    assert_receive {:ui, "/ui/openwindow/marketdetails", %{"type_id" => ^type_id}}, 2_000
    assert render_async(view) =~ "Mercado abierto en el juego"
  end
end
