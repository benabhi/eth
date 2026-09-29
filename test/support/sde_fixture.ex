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
        }
      ],
      "groups" => [
        %{"_key" => 18, "name" => %{"en" => "Mineral"}, "categoryID" => 4},
        %{"_key" => 28, "name" => %{"en" => "Hauler"}, "categoryID" => 6}
      ],
      "categories" => [
        %{"_key" => 4, "name" => %{"en" => "Material"}},
        %{"_key" => 6, "name" => %{"en" => "Ship"}}
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
    %{"_key" => id, "solarSystemID" => from, "destination" => %{"solarSystemID" => to}}
  end
end
