defmodule Eth.Characters.PilotTest do
  use Eth.DataCase, async: false

  alias Eth.Characters
  alias Eth.Characters.{Character, Pilot}
  alias Eth.EngineFixture, as: F

  @moduletag :tmp_dir

  @character %Character{id: 2_112_345_678, name: "Hernan Test", scopes: ["a"]}

  defp session(context) do
    %{id: @character.id, name: "Hernan Test", status: :ok, scopes: ["a", "b"], context: context}
  end

  setup %{tmp_dir: tmp_dir} do
    :ok = F.load_sde(tmp_dir)
  end

  test "capital, Accounting y clase de evasión se derivan de las reglas del juego" do
    assert Pilot.capital(nil) == nil
    assert Pilot.capital(5.0e9) == 5.0e9
    assert Pilot.accounting_level(nil) == nil
    assert Pilot.accounting_level(%{}) == 0
    assert Pilot.accounting_level(%{16_622 => 5}) == 5
    assert Pilot.evasion_class(28) == :industrial
    assert Pilot.evasion_class(1202) == :blockade_runner
    assert Pilot.evasion_class(nil) == :other
  end

  test "sin contexto todavía, el piloto no cambia los defaults del motor" do
    pilot = Pilot.build(nil, @character)

    assert pilot.status == :starting
    assert pilot.portrait_url =~ "/characters/2112345678/portrait"
    # Sin contexto no cambia los defaults del motor; solo identifica al personaje (AS-8).
    assert Pilot.query_overrides(pilot) == %{character_id: pilot.id}
    assert Pilot.build(nil, %{@character | token_status: "relogin"}).status == :relogin
  end

  test "con contexto completo personaliza impuestos, capital, bodega y origen" do
    pilot =
      Pilot.build(
        session(%{
          online: true,
          wallet: 1.25e9,
          skills: %{16_622 => 5},
          location: %{solar_system_id: F.jita(), station_id: F.jita_44()},
          ship: %{ship_type_id: 657, ship_item_id: 1_001, ship_name: "Carguero"}
        }),
        @character
      )

    assert pilot.sales_tax < 0.075
    assert pilot.location.system_name == "Jita"
    assert pilot.ship.type_name == "Iteron Mark V"
    assert pilot.ship.render_url =~ "/types/657/render"
    # Sin perfil: capacidad base del SDE, sin confirmar (RF-5.8).
    refute pilot.ship.cargo_confirmed
    assert Pilot.at_location?(pilot, F.jita_44())
    refute Pilot.at_location?(pilot, F.perimeter_station())

    assert Pilot.query_overrides(pilot) == %{
             accounting: 5,
             capital: 1.25e9,
             cargo_m3: 5_800.0,
             ship_class: :industrial,
             base_system_id: F.jita(),
             character_id: pilot.id
           }

    # Con perfil guardado manda el perfil.
    {:ok, _} =
      Characters.save_ship_profile(1_001, 657, %{cargo_m3: 38_500, evasion_class: "freighter"})

    ship = %{ship_type_id: 657, ship_item_id: 1_001, ship_name: "Carguero"}
    pilot = Pilot.build(session(%{ship: ship}), @character)

    assert pilot.ship.cargo_confirmed
    assert %{cargo_m3: 38_500.0, ship_class: :freighter} = Pilot.query_overrides(pilot)
  end
end
