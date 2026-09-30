defmodule EthWeb.SettingsLiveTest do
  use EthWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Eth.{Characters, GameRules}
  alias Eth.GameRules.Overrides
  alias Eth.Market.Structures
  alias Eth.Sso.Jwt
  alias Eth.SsoFixture, as: F

  @moduletag :capture_log

  @id 2_112_345_678

  setup do
    start_supervised!(Overrides)
    :ok
  end

  defp character(scopes) do
    {:ok, character} =
      Characters.upsert_login(%{
        character_id: @id,
        name: "Hernan Test",
        owner_hash: "owner-hash-1",
        scopes: scopes,
        access_token: "access-1",
        refresh_token: "refresh-1",
        expires_at: DateTime.add(DateTime.utc_now(), 1199, :second)
      })

    character
  end

  test "personajes: muestra los scopes que faltan y permite olvidar", %{conn: conn} do
    character(Eth.Sso.scopes() -- ["esi-assets.read_assets.v1"])
    Jwt.clear_cache()
    F.stub(F.keys(), %{})

    {:ok, view, _html} = live(conn, ~p"/settings")

    assert has_element?(view, "#character-#{@id}", "Hernan Test")
    assert has_element?(view, "#character-#{@id}", "esi-assets.read_assets.v1")
    assert has_element?(view, "#settings-activate-#{@id}")

    view |> element("#forget-#{@id}") |> render_click()
    refute has_element?(view, "#character-#{@id}")
    assert has_element?(view, "#characters-empty")
    assert Characters.get(@id) == nil
  end

  test "naves: edita y borra perfiles de carga", %{conn: conn} do
    {:ok, profile} =
      Characters.save_ship_profile(1_001, 657, %{cargo_m3: 5_000, evasion_class: "industrial"})

    {:ok, view, _html} = live(conn, ~p"/settings/ships")
    assert has_element?(view, "#profile-#{profile.id}", "5,000")

    view |> element("#edit-profile-#{profile.id}") |> render_click()

    view
    |> form("#ship-edit-form", ship_profile: %{cargo_m3: "0"})
    |> render_change()

    assert has_element?(view, "#ship-edit-form", "debe ser mayor que 0")

    view
    |> form("#ship-edit-form", ship_profile: %{cargo_m3: "38500", evasion_class: "freighter"})
    |> render_submit()

    assert has_element?(view, "#profile-#{profile.id}", "38,500")
    assert Characters.get_ship_profile(profile.id).evasion_class == "freighter"

    view |> element("#delete-profile-#{profile.id}") |> render_click()
    assert has_element?(view, "#ships-empty")
  end

  test "reglas: guarda un override en porcentaje y lo restablece", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings/rules")
    assert has_element?(view, "#rule-sales_tax_base", "7.5 %")

    view |> form("#rules-form", rules: %{sales_tax_base: "8,25"}) |> render_submit()
    assert_in_delta GameRules.get(:sales_tax_base), 0.0825, 1.0e-12

    view |> element("#reset-sales_tax_base") |> render_click()
    assert GameRules.get(:sales_tax_base) == 0.075

    view |> form("#rules-form", rules: %{sales_tax_base: "150"}) |> render_submit()
    assert GameRules.get(:sales_tax_base) == 0.075
  end

  test "primer arranque: checklist con el estado de cada paso", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings/setup")

    # En tests el SSO está configurado, pero no hay SDE ni personajes.
    assert has_element?(view, "#check-env[data-ok='true']")
    assert has_element?(view, "#check-sso[data-ok='false']")
    assert has_element?(view, "#check-sde[data-ok='false']")
  end

  test "parse_percent/1 acepta coma o punto y rechaza fuera de rango" do
    assert EthWeb.SettingsLive.parse_percent("7,5") == {:ok, 0.075}
    assert EthWeb.SettingsLive.parse_percent(" ") == :blank
    assert EthWeb.SettingsLive.parse_percent("abc") == :error
    assert EthWeb.SettingsLive.parse_percent("101") == :error
  end

  describe "radar (RF-9.5)" do
    @describetag :tmp_dir

    setup %{tmp_dir: tmp_dir} do
      :ok = Eth.EngineFixture.load_sde(tmp_dir)
    end

    test "guarda α y los sistemas a evitar, y los publica como reglas", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/radar")

      view
      |> form("#radar-form", radar: %{evasive_alpha: "35", avoid: "perimeter, Ahbazon"})
      |> render_submit()

      assert render(view) =~ "Radar guardado"
      assert GameRules.get(:evasive_alpha) == 35.0
      assert Enum.sort(GameRules.get(:avoid_system_ids)) == [30_000_144, 30_005_196]
      assert has_element?(view, "#radar-form textarea", "Perimeter, Ahbazon")

      # Vacío: vuelve al valor por defecto y no evita nada.
      view |> form("#radar-form", radar: %{evasive_alpha: "", avoid: ""}) |> render_submit()
      assert GameRules.get(:evasive_alpha) == GameRules.default(:evasive_alpha)
      assert GameRules.get(:avoid_system_ids) == []
    end

    test "rechaza sistemas desconocidos y α fuera de rango", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/radar")

      view |> form("#radar-form", radar: %{avoid: "Narnia"}) |> render_submit()
      assert render(view) =~ "Sistemas desconocidos: Narnia"

      view |> form("#radar-form", radar: %{evasive_alpha: "500", avoid: ""}) |> render_submit()
      assert render(view) =~ "α tiene que ser un número entre 0 y 100"
      assert GameRules.get(:avoid_system_ids) == []
    end
  end

  describe "regiones y estructuras (RF-9.6)" do
    test "lista las estructuras, agrega por ID y guarda seguir y broker fee", %{conn: conn} do
      {:ok, _} = Structures.follow(1_035_466_617_946)
      {:ok, view, _html} = live(conn, ~p"/settings/markets")
      assert has_element?(view, "#structure-1035466617946", "Sin resolver")

      view |> form("#structure-add", structure: %{id: "1022167642188"}) |> render_submit()
      assert has_element?(view, "#structure-1022167642188")
      assert Structures.get(1_022_167_642_188).followed

      view
      |> element("#structure-1022167642188 input[type=checkbox]")
      |> render_click()

      refute Structures.get(1_022_167_642_188).followed

      view
      |> element("#structure-1035466617946 form")
      |> render_submit(%{"structure_id" => "1035466617946", "fee" => "1.5"})

      assert Structures.get(1_035_466_617_946).broker_fee_override == 0.015

      view |> form("#structure-add", structure: %{id: "abc"}) |> render_submit()
      assert render(view) =~ "tiene que ser un número"
    end
  end

  describe "notificaciones (RF-10.2, RF-10.3)" do
    test "guarda la regla y muestra una alerta de prueba como toast", %{conn: conn} do
      start_supervised!(Eth.Notifications.Dispatcher)
      {:ok, view, _html} = live(conn, ~p"/settings/notifications")
      assert has_element?(view, "#notify-status")
      assert has_element?(view, "#eth-notifier[phx-hook]")

      view
      |> form("#rule-form", rule: %{enabled: "true", min_tvs: "80", min_profit: "50M"})
      |> render_submit()

      assert %{enabled: true, min_tvs: 80, min_profit: 50_000_000} = Eth.Notifications.rule()

      view |> element("#notify-test") |> render_click()
      assert render(view) =~ "Alerta de prueba"
    end
  end

  describe "respaldo (RF-9.7)" do
    test "descarga la configuración como JSON", %{conn: conn} do
      conn = get(conn, ~p"/settings/export")

      assert response(conn, 200)
      assert [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "eth-config-"
      assert %{"app" => "eth", "format" => 1} = Jason.decode!(conn.resp_body)
    end

    test "importa un archivo y muestra el resumen", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/backup")

      json =
        Jason.encode!(%{
          "app" => "eth",
          "format" => 1,
          "game_rules" => %{"sales_tax_base" => 0.05}
        })

      file =
        file_input(view, "#config-import", :config, [
          %{name: "eth-config.json", content: json, type: "application/json"}
        ])

      render_upload(file, "eth-config.json")
      view |> form("#config-import") |> render_submit()

      assert has_element?(view, "#import-result", "Configuración importada")
      assert Eth.Accounts.game_rule_overrides() == %{sales_tax_base: 0.05}
      Overrides.reload()
    end

    test "un archivo que no es JSON muestra el error", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/backup")

      file =
        file_input(view, "#config-import", :config, [
          %{name: "roto.json", content: "{no", type: "application/json"}
        ])

      render_upload(file, "roto.json")
      view |> form("#config-import") |> render_submit()
      assert has_element?(view, "#import-result", "no es un JSON válido")
    end
  end
end
