defmodule EthWeb.SettingsLiveTest do
  use EthWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Eth.{Characters, GameRules}
  alias Eth.GameRules.Overrides
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
end
