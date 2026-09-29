defmodule Eth.SdeFixture do
  @moduledoc """
  SDE mínimo con el formato real (JSONL) para tests sin red: tres sistemas de The Forge
  en cadena (Jita — Perimeter — Ahbazon, este último lowsec), una estación y un tipo.
  """

  @build 3_552_227

  @doc "Build simulado."
  @spec build() :: pos_integer()
  def build, do: @build

  @doc "Archivos del SDE como `%{nombre => [registros]}`."
  @spec files() :: %{String.t() => [map()]}
  def files do
    %{
      "mapRegions" => [%{"_key" => 10_000_002, "name" => %{"en" => "The Forge"}}],
      "mapSolarSystems" => [
        system(30_000_142, "Jita", 0.945913),
        system(30_000_144, "Perimeter", 0.949),
        system(30_005_196, "Ahbazon", 0.421)
      ],
      "mapStargates" => [
        gate(1, 30_000_142, 30_000_144),
        gate(2, 30_000_144, 30_000_142),
        gate(3, 30_000_144, 30_005_196),
        gate(4, 30_005_196, 30_000_144)
      ],
      "npcStations" => [
        %{
          "_key" => 60_003_760,
          "celestialIndex" => 4,
          "orbitIndex" => 4,
          "operationID" => 14,
          "ownerID" => 1_000_035,
          "solarSystemID" => 30_000_142,
          "useOperationName" => true
        },
        # Estación NPC en Perimeter (1 salto de Jita) para la familia por órdenes.
        %{
          "_key" => 60_000_004,
          "celestialIndex" => 8,
          "orbitIndex" => 1,
          "operationID" => 14,
          "ownerID" => 1_000_035,
          "solarSystemID" => 30_000_144,
          "useOperationName" => true
        }
      ],
      "npcCorporations" => [
        %{"_key" => 1_000_035, "name" => %{"en" => "Caldari Navy"}, "factionID" => 500_001}
      ],
      "stationOperations" => [%{"_key" => 14, "operationName" => %{"en" => "Assembly Plant"}}],
      "types" => [
        %{
          "_key" => 34,
          "name" => %{"en" => "Tritanium"},
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
          "volume" => 275_000,
          "packagedVolume" => 20_000,
          "capacity" => 5_800
        },
        # Radar: cápsula (fuera del mercado), Sabre (interdictor), Tornado y una smartbomb.
        %{"_key" => 670, "name" => %{"en" => "Capsule"}, "groupID" => 29, "published" => false},
        %{
          "_key" => 22_456,
          "name" => %{"en" => "Sabre"},
          "groupID" => 541,
          "marketGroupID" => 1_070,
          "published" => true
        },
        %{
          "_key" => 4_310,
          "name" => %{"en" => "Tornado"},
          "groupID" => 1_201,
          "marketGroupID" => 1_376,
          "published" => true
        },
        %{
          "_key" => 3_561,
          "name" => %{"en" => "Large EMP Smartbomb I"},
          "groupID" => 72,
          "marketGroupID" => 382,
          "published" => true
        }
      ],
      "groups" => [
        %{"_key" => 18, "name" => %{"en" => "Mineral"}, "categoryID" => 4},
        %{"_key" => 28, "name" => %{"en" => "Hauler"}, "categoryID" => 6},
        %{"_key" => 29, "name" => %{"en" => "Capsule"}, "categoryID" => 6},
        %{"_key" => 541, "name" => %{"en" => "Interdictor"}, "categoryID" => 6},
        %{"_key" => 1_201, "name" => %{"en" => "Attack Battlecruiser"}, "categoryID" => 6},
        %{"_key" => 72, "name" => %{"en" => "Smart Bomb"}, "categoryID" => 7}
      ],
      "categories" => [
        %{"_key" => 4, "name" => %{"en" => "Material"}},
        %{"_key" => 6, "name" => %{"en" => "Ship"}},
        %{"_key" => 7, "name" => %{"en" => "Module"}}
      ],
      # Dogma real (SDE 3552227) de la Iteron Mark V (657), Expanded Cargohold II (1319) y
      # la habilidad Gallente Hauler (3340), más un tipo sin relación con la bodega (34).
      "typeDogma" => [
        %{
          "_key" => 657,
          "dogmaAttributes" => [
            %{"attributeID" => 496, "value" => 5.0},
            %{"attributeID" => 37, "value" => 105.0}
          ],
          "dogmaEffects" => [%{"effectID" => 726}, %{"effectID" => 729}]
        },
        %{
          "_key" => 1319,
          "dogmaAttributes" => [
            %{"attributeID" => 149, "value" => 1.275},
            %{"attributeID" => 306, "value" => 0.82}
          ],
          "dogmaEffects" => [%{"effectID" => 59}, %{"effectID" => 3046}]
        },
        %{
          "_key" => 3340,
          "dogmaAttributes" => [
            %{"attributeID" => 275, "value" => 4.0},
            %{"attributeID" => 280, "value" => 0.0}
          ],
          "dogmaEffects" => [%{"effectID" => 132}, %{"effectID" => 532}]
        },
        %{"_key" => 34, "dogmaAttributes" => [%{"attributeID" => 182, "value" => 3386.0}]}
      ],
      "dogmaEffects" => [
        effect(726, "shipBonusCargo2GI", [ship_mod(38, 496, 6)]),
        effect(729, "shipBonusVelocityGI", [ship_mod(37, 496, 6)]),
        effect(59, "cargoCapacityMultiply", [ship_mod(38, 149, 4)]),
        effect(3046, "modifyMaxVelocityOfShipPassive", [ship_mod(37, 306, 4)]),
        effect(132, "skillEffect", [
          %{
            "domain" => "itemID",
            "func" => "ItemModifier",
            "modifiedAttributeID" => 280,
            "modifyingAttributeID" => 276,
            "operation" => 2
          }
        ]),
        effect(532, "gallenteIndustrialSkillLevelPreMulShipBonusGIShip", [ship_mod(496, 280, 0)])
      ],
      "dogmaAttributes" => [
        %{"_key" => 38, "defaultValue" => 0.0, "stackable" => true},
        %{"_key" => 37, "defaultValue" => 0.0, "stackable" => false},
        %{"_key" => 149, "defaultValue" => 1.0, "stackable" => true},
        %{"_key" => 496, "defaultValue" => 5.0, "stackable" => true},
        %{"_key" => 280, "defaultValue" => 0.0, "stackable" => true},
        %{"_key" => 276, "defaultValue" => 0.0, "stackable" => true}
      ]
    }
  end

  @doc "Escribe los JSONL en `dir`."
  @spec write(Path.t()) :: :ok
  def write(dir) do
    File.mkdir_p!(dir)

    for {name, rows} <- files() do
      File.write!(
        Path.join(dir, name <> ".jsonl"),
        Enum.map_join(rows, "\n", &Jason.encode!/1) <> "\n"
      )
    end

    :ok
  end

  @doc "Zip del SDE en memoria (como el que publica CCP)."
  @spec zip_binary(Path.t()) :: binary()
  def zip_binary(tmp_dir) do
    src = Path.join(tmp_dir, "sde-src")
    write(src)
    names = src |> File.ls!() |> Enum.map(&String.to_charlist/1)

    {:ok, {_name, binary}} =
      :zip.create(~c"sde.zip", names, [:memory, cwd: String.to_charlist(src)])

    binary
  end

  defp effect(id, name, modifiers),
    do: %{"_key" => id, "name" => name, "modifierInfo" => modifiers}

  defp ship_mod(modified, modifying, operation) do
    %{
      "domain" => "shipID",
      "func" => "ItemModifier",
      "modifiedAttributeID" => modified,
      "modifyingAttributeID" => modifying,
      "operation" => operation
    }
  end

  defp system(id, name, sec) do
    %{
      "_key" => id,
      "name" => %{"en" => name},
      "regionID" => 10_000_002,
      "constellationID" => 20_000_020,
      "securityStatus" => sec
    }
  end

  defp gate(id, from, to) do
    %{
      "_key" => id,
      "solarSystemID" => from,
      "destination" => %{"solarSystemID" => to, "stargateID" => id + 100}
    }
  end
end
