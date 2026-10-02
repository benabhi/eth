defmodule Eth.Sde.ProcessorTest do
  use ExUnit.Case, async: true

  alias Eth.Sde.Processor

  @moduletag :tmp_dir

  # Mini SDE con el formato real (JSONL, nombres localizados, _key como ID).
  @files %{
    "mapRegions" => [%{"_key" => 10_000_002, "name" => %{"en" => "The Forge"}}],
    "mapSolarSystems" => [
      %{
        "_key" => 30_000_142,
        "name" => %{"en" => "Jita"},
        "regionID" => 10_000_002,
        "constellationID" => 20_000_020,
        "securityStatus" => 0.945913,
        "position" => %{"x" => -1.29e17, "y" => 6.07e16, "z" => 1.17e17}
      },
      %{
        "_key" => 30_000_144,
        "name" => %{"en" => "Perimeter"},
        "regionID" => 10_000_002,
        "constellationID" => 20_000_020,
        "securityStatus" => 1
      }
    ],
    "mapStargates" => [
      %{
        "_key" => 1,
        "solarSystemID" => 30_000_142,
        "destination" => %{"solarSystemID" => 30_000_144}
      },
      %{
        "_key" => 2,
        "solarSystemID" => 30_000_144,
        "destination" => %{"solarSystemID" => 30_000_142}
      }
    ],
    "npcStations" => [
      # Jita IV - Moon 4: el nombre se compone (ESI no lo devuelve en este test).
      %{
        "_key" => 60_003_760,
        "celestialIndex" => 4,
        "orbitIndex" => 4,
        "operationID" => 14,
        "ownerID" => 1_000_035,
        "solarSystemID" => 30_000_142,
        "useOperationName" => true
      },
      # Sin luna: orbita el planeta. Su nombre sí lo resuelve "ESI".
      %{
        "_key" => 60_000_001,
        "celestialIndex" => 8,
        "operationID" => 14,
        "ownerID" => 1_000_035,
        "solarSystemID" => 30_000_144,
        "useOperationName" => false
      }
    ],
    "npcCorporations" => [
      %{"_key" => 1_000_035, "name" => %{"en" => "Caldari Navy"}, "factionID" => 500_001}
    ],
    "stationOperations" => [%{"_key" => 14, "operationName" => %{"en" => "Assembly Plant"}}],
    "types" => [
      %{
        "_key" => 34,
        "name" => %{"en" => "Tritanium", "es" => "Tritanio"},
        "groupID" => 18,
        "marketGroupID" => 1857,
        "published" => true,
        "volume" => 0.01,
        "packagedVolume" => 0.01
      },
      %{
        "_key" => 657,
        "name" => %{"en" => "Iteron Mark V"},
        "groupID" => 28,
        "marketGroupID" => 83,
        "published" => true,
        "volume" => 275_000.0,
        "packagedVolume" => 20_000.0,
        "capacity" => 5800.0
      },
      # Sin grupo de mercado o sin publicar: se descartan.
      %{"_key" => 1, "name" => %{"en" => "Interno"}, "groupID" => 0, "published" => true},
      %{
        "_key" => 2,
        "name" => %{"en" => "Oculto"},
        "groupID" => 18,
        "marketGroupID" => 1,
        "published" => false
      }
    ],
    "groups" => [%{"_key" => 28, "name" => %{"en" => "Industrial"}, "categoryID" => 6}],
    "categories" => [%{"_key" => 6, "name" => %{"en" => "Ship"}}],
    # Dogma mínimo: el cálculo de la bodega se prueba en Eth.Sde.DogmaTest.
    "typeDogma" => [%{"_key" => 34, "dogmaAttributes" => [], "dogmaEffects" => []}],
    "dogmaEffects" => [%{"_key" => 11, "name" => "loPower"}],
    "dogmaAttributes" => [%{"_key" => 38, "defaultValue" => 0.0, "stackable" => true}]
  }

  defp write_files(dir, files \\ @files) do
    for {name, rows} <- files do
      File.write!(
        Path.join(dir, name <> ".jsonl"),
        Enum.map_join(rows, "\n", &Jason.encode!/1) <> "\n"
      )
    end
  end

  test "procesa sistemas, vecinos, estaciones, tipos y grupos", %{tmp_dir: dir} do
    write_files(dir)

    resolver = fn ids ->
      if 60_000_001 in ids, do: %{60_000_001 => "Perimeter VIII - Nombre Oficial"}, else: %{}
    end

    data = Processor.process(dir, resolver)

    assert data.regions == %{10_000_002 => %{name: "The Forge"}}

    assert %{name: "Jita", region_id: 10_000_002, security: 0.945913, neighbors: [30_000_144]} =
             data.systems[30_000_142]

    # La seguridad entera del JSON se normaliza a float.
    assert data.systems[30_000_144].security === 1.0

    # Posición para el mapa (RF-8.2): X y Z del SDE; sin `position`, nil.
    assert %{x: -1.29e17, z: 1.17e17} = data.systems[30_000_142]
    assert %{x: nil, z: nil} = data.systems[30_000_144]

    assert data.stations[60_003_760] == %{
             name: "Jita IV - Moon 4 - Caldari Navy Assembly Plant",
             system_id: 30_000_142,
             region_id: 10_000_002,
             owner_id: 1_000_035
           }

    assert data.stations[60_000_001].name == "Perimeter VIII - Nombre Oficial"

    assert Map.keys(data.types) |> Enum.sort() == [34, 657]
    assert data.types[34].name_es == "Tritanio"
    # Sin traducción al español: se usa el nombre en inglés.
    assert data.types[657].name_es == "Iteron Mark V"
    assert data.types[657].packaged_volume == 20_000.0
    assert data.types[657].capacity == 5800.0

    assert data.groups[28] == %{name: "Industrial", category_id: 6}
    # Radar: grupo de las naves (categoría 6), estén o no en el mercado; gates con destino.
    assert data.type_groups == %{657 => 28}
    assert data.stargates[1] == %{system_id: 30_000_142, destination_system_id: 30_000_144}
    assert data.categories[6] == "Ship"
    assert data.corporations[1_000_035].faction_id == 500_001
  end

  test "extrae del zip solo los archivos necesarios", %{tmp_dir: dir} do
    src = Path.join(dir, "src")
    File.mkdir_p!(src)
    write_files(src)
    File.write!(Path.join(src, "mapMoons.jsonl"), "{}\n")

    zip = Path.join(dir, "sde.zip")
    names = src |> File.ls!() |> Enum.map(&String.to_charlist/1)
    {:ok, _} = :zip.create(String.to_charlist(zip), names, cwd: String.to_charlist(src))

    out = Path.join(dir, "out")
    assert :ok = Processor.extract(zip, out)
    assert File.exists?(Path.join(out, "types.jsonl"))
    refute File.exists?(Path.join(out, "mapMoons.jsonl"))
  end

  test "un SDE nuevo con números faltantes no rompe el procesamiento", %{tmp_dir: dir} do
    files =
      @files
      |> Map.update!("mapSolarSystems", fn systems ->
        systems ++
          [
            %{
              "_key" => 30_000_999,
              "name" => %{"en" => "Sin Datos"},
              "regionID" => 10_000_002,
              "constellationID" => 20_000_020
            }
          ]
      end)
      |> Map.update!("dogmaAttributes", &[%{"_key" => 38, "defaultValue" => nil} | tl(&1)])

    write_files(dir, files)
    data = Processor.process(dir, fn _ids -> %{} end)

    # Sin seguridad: null-sec (lo más conservador para las rutas); sin posición, fuera del mapa.
    assert %{security: -1.0, x: nil, z: nil} = data.systems[30_000_999]
    assert data.systems[30_000_142].security == 0.945913
  end

  test "números romanos de planetas" do
    assert Enum.map([1, 4, 8, 9, 12, 14, 19], &Processor.roman/1) ==
             ["I", "IV", "VIII", "IX", "XII", "XIV", "XIX"]
  end
end
