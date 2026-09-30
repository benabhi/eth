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

    assert has_element?(view, "#opportunities [id^='opp-'] > [data-head]", "Tritanium")
    assert has_element?(view, "#hunter-status", "1 oportunidades")
    # Bodega por defecto 38.500 m³: 3.850.000 unidades de 0,01 m³.
    assert has_element?(view, "#opportunities", "3,850,000")
  end

  test "los filtros viajan en la URL y filtran", %{conn: conn} do
    publish_market()
    {:ok, view, _html} = live(conn, ~p"/")

    view |> form("#filters", filters: %{search: "amarr"}) |> render_change()
    assert_patch(view, ~p"/?search=amarr")
    refute has_element?(view, "#opportunities [id^='opp-'] > [data-head]")

    # La URL restaura la vista.
    {:ok, view, _html} = live(conn, ~p"/?search=perimeter&cargo_m3=100&min_profit=1k")
    assert has_element?(view, "#opportunities [id^='opp-'] > [data-head]", "10,000")
  end

  test "el detalle explica el cálculo y ofrece Multibuy", %{conn: conn} do
    publish_market()
    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("#opportunities [id^='opp-'] > [data-head]") |> render_click()
    render_async(view)
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

  test "la ficha se despliega bajo la fila, congela la grilla y se cierra (RF-6.5)", %{conn: conn} do
    publish_market()
    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("#opportunities [id^='opp-'] > [data-head]") |> render_click()
    render_async(view)
    assert has_element?(view, "#opportunities [id^='opp-'] #detail")
    assert has_element?(view, "[data-head][aria-expanded='true']")

    # Mientras está abierta, los cambios quedan pendientes.
    publish_market(6.0)
    assert render(view) =~ "1 cambio pendiente"

    # Al cerrarla se aplican.
    view |> element("#close-detail") |> render_click()
    refute has_element?(view, "#detail")
    refute render(view) =~ "cambio pendiente"

    # Otro clic en la misma fila la abre y la cierra.
    view |> element("#opportunities [id^='opp-'] > [data-head]") |> render_click()
    assert has_element?(view, "#detail")
    view |> element("#opportunities [id^='opp-'] > [data-head]") |> render_click()
    refute has_element?(view, "#detail")
  end

  test "todos los \"?\" de la fila y de la ficha tienen texto de ayuda (RNF-5.14)", %{conn: conn} do
    publish_market()
    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("#opportunities [id^='opp-'] > [data-head]") |> render_click()
    render_async(view)

    tooltips = view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query("[role=tooltip]")
    assert Enum.count(tooltips) > 10

    for tooltip <- tooltips do
      text = tooltip |> LazyHTML.query("[data-tip-text]") |> LazyHTML.text() |> String.trim()
      assert text != "", "tooltip sin texto: #{LazyHTML.to_html(tooltip)}"
    end
  end

  test "las filas que cambian se resaltan un momento (RF-6.3)", %{conn: conn} do
    publish_market()
    {:ok, view, _html} = live(conn, ~p"/")

    # Primera carga: nada resaltado.
    refute has_element?(view, "#opportunities [class*='eth-flash-']")

    # Otra evaluación con otro precio: la fila cambia y se resalta.
    publish_market(6.0)
    assert has_element?(view, "#opportunities [id^='opp-'][class*='eth-flash-']")
  end

  test "una fila que expira queda tachada un momento antes de salir (RF-6.3)", %{conn: conn} do
    publish_market()
    {:ok, view, _html} = live(conn, ~p"/")
    [_, id] = Regex.run(~r/id="opp-([^"]+)"/, render(view))

    # Sin margen: el contrato desaparece de la evaluación.
    publish_market(3.0)
    assert has_element?(view, "#opp-#{id} [data-expired]", "Tritanium")
    refute has_element?(view, "#opp-#{id} [data-head]")

    send(view.pid, {:drop_expired, [id]})
    refute has_element?(view, "#opp-#{id}")
  end

  test "con el puntero sobre la grilla los cambios quedan pendientes (RF-6.3)", %{conn: conn} do
    publish_market()
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#board-hold[phx-hook][data-enabled='true']")
    render_hook(view, "hover_hold", %{"on" => true})
    publish_market(6.0)
    assert render(view) =~ "1 cambio pendiente"

    render_hook(view, "hover_hold", %{"on" => false})
    refute render(view) =~ "cambio pendiente"
  end

  test "los atajos de teclado tienen su hook y sus destinos marcados (RF-6.9)", %{conn: conn} do
    publish_market()
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#board-shortcuts[phx-hook]")
    assert has_element?(view, "input[data-shortcut=search]")
    assert has_element?(view, "#freeze[data-shortcut=freeze]")
    assert has_element?(view, "[data-head][tabindex='0']")

    view |> element("#opportunities [id^='opp-'] > [data-head]") |> render_click()
    assert has_element?(view, "#copy-detail[data-shortcut=copy]")
    assert has_element?(view, "#set-route[data-shortcut=route]")
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
      refute has_element?(view, "#opportunities [id^='opp-'] > [data-head]")

      {:ok, view, _html} = live(conn, ~p"/?shield=all")
      assert has_element?(view, "#opportunities", "Scam · bloqueado")

      view |> element("#opportunities [id^='opp-'] > [data-head]") |> render_click()
      render_async(view)
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

      view |> element("#opportunities [id^='opp-'] > [data-head]") |> render_click()
      render_async(view)
      refute has_element?(view, "#shield-alert")
      assert has_element?(view, "#history svg polyline")
      assert has_element?(view, "#history", "30 / 30")
    end
  end

  describe "radar en la ruta (RF-4.12, RF-2.5)" do
    setup do
      start_supervised!(Eth.Threat.Radar)

      :ets.insert(
        :eth_threat_heat,
        {F.perimeter(),
         %{
           system_id: F.perimeter(),
           kills: 5,
           intensity: 5.0,
           lambda: 0.05,
           alert: true,
           threat: 0.9,
           classification: %{
             type: :gate_camp,
             confidence: 0.8,
             description: "Gatecamp en el gate a Jita"
           },
           updated_at: DateTime.utc_now()
         }}
      )

      :ok
    end

    test "marca la alerta en la fila y la explica en la sección Ruta", %{conn: conn} do
      publish_market()

      for mode <- ["secure", "evasive"] do
        {:ok, view, _html} = live(conn, ~p"/?route_mode=#{mode}")
        assert has_element?(view, "#opportunities", "Gatecamp · Perimeter")

        view |> element("#opportunities [id^='opp-'] > [data-head]") |> render_click()
        render_async(view)
        assert has_element?(view, "#route", "Perimeter: Gatecamp en el gate a Jita")
        assert has_element?(view, "#detail", "Ruta (amenazas y riesgo base)")
      end
    end
  end
end
