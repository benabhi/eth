defmodule Eth.Sde.Processor do
  @moduledoc """
  Convierte el SDE JSONL en las estructuras compactas que usa la aplicación (RF-2.2,
  RF-2.3). Extrae del zip solo los archivos necesarios y los procesa línea por línea.

  Resultado (`t:data/0`):

  - `regions`: `id => %{name}`
  - `systems`: `id => %{name, region_id, constellation_id, security, neighbors}`
  - `stations`: `id => %{name, system_id, region_id, owner_id}`
  - `corporations`: `id => %{name, faction_id}`
  - `types`: solo tipos publicados con grupo de mercado:
    `id => %{name, name_es, group_id, market_group_id, volume, packaged_volume, capacity}`
  - `groups`: `id => %{name, category_id}` y `categories`: `id => name`

  Los nombres de estaciones no vienen armados en el SDE; se resuelven con una función
  externa (ESI `/universe/names`, exacta) y, si falta alguno, se componen con la regla
  del cliente ("Jita IV - Moon 4 - Caldari Navy Assembly Plant"), que no contempla los
  planetas con nombre propio ("Amarr VIII (Oris)").
  """

  @files ~w(mapRegions mapSolarSystems mapStargates npcStations npcCorporations stationOperations
            types groups categories)

  @type data :: %{
          regions: map(),
          systems: map(),
          stations: map(),
          corporations: map(),
          types: map(),
          groups: map(),
          categories: map()
        }

  @doc "Extrae del zip los archivos necesarios en `dir`."
  @spec extract(Path.t(), Path.t()) :: :ok | {:error, term()}
  # Las rutas del procesador son el directorio de datos más nombres de archivo fijos del
  # SDE (@files); nunca entrada externa.
  # sobelow_skip ["Traversal.FileModule"]
  def extract(zip_path, dir) do
    File.mkdir_p!(dir)
    files = Enum.map(@files, &String.to_charlist(&1 <> ".jsonl"))

    case :zip.unzip(String.to_charlist(zip_path), file_list: files, cwd: String.to_charlist(dir)) do
      {:ok, _extracted} -> :ok
      {:error, reason} -> {:error, {:zip, reason}}
    end
  end

  @doc """
  Procesa los JSONL extraídos en `dir`. `resolve_station_names` recibe la lista de IDs
  de estaciones y devuelve `%{id => nombre}` (puede ser parcial o vacío).
  """
  @spec process(Path.t(), ([pos_integer()] -> %{pos_integer() => String.t()})) :: data()
  def process(dir, resolve_station_names) do
    regions = dir |> stream("mapRegions") |> Map.new(&{&1["_key"], %{name: en(&1["name"])}})
    neighbors = dir |> stream("mapStargates") |> neighbors()

    systems =
      dir
      |> stream("mapSolarSystems")
      |> Map.new(fn s ->
        {s["_key"],
         %{
           name: en(s["name"]),
           region_id: s["regionID"],
           constellation_id: s["constellationID"],
           security: s["securityStatus"] / 1,
           neighbors: neighbors |> Map.get(s["_key"], []) |> Enum.uniq() |> Enum.sort()
         }}
      end)

    corporations =
      dir
      |> stream("npcCorporations")
      |> Map.new(&{&1["_key"], %{name: en(&1["name"]), faction_id: &1["factionID"]}})

    operations =
      dir |> stream("stationOperations") |> Map.new(&{&1["_key"], en(&1["operationName"])})

    raw_stations = dir |> stream("npcStations") |> Enum.to_list()
    names = resolve_station_names.(Enum.map(raw_stations, & &1["_key"]))

    stations =
      Map.new(raw_stations, fn st ->
        system = Map.fetch!(systems, st["solarSystemID"])

        {st["_key"],
         %{
           name:
             Map.get(names, st["_key"]) ||
               compose_station_name(st, system, corporations, operations),
           system_id: st["solarSystemID"],
           region_id: system.region_id,
           owner_id: st["ownerID"]
         }}
      end)

    groups =
      dir
      |> stream("groups")
      |> Map.new(&{&1["_key"], %{name: en(&1["name"]), category_id: &1["categoryID"]}})

    categories = dir |> stream("categories") |> Map.new(&{&1["_key"], en(&1["name"])})

    %{
      regions: regions,
      systems: systems,
      stations: stations,
      corporations: corporations,
      types: types(dir),
      groups: groups,
      categories: categories
    }
  end

  @doc """
  Nombre de estación con la regla del cliente:
  `<sistema> <planeta romano>[ - Moon <n>] - <corporación>[ <operación>]`.
  """
  @spec compose_station_name(map(), map(), map(), map()) :: String.t()
  def compose_station_name(station, system, corporations, operations) do
    planet = "#{system.name} #{roman(station["celestialIndex"])}"
    moon = if station["orbitIndex"], do: " - Moon #{station["orbitIndex"]}", else: ""
    corp = get_in(corporations, [station["ownerID"], :name]) || "?"

    operation =
      if station["useOperationName"],
        do: " " <> (operations[station["operationID"]] || ""),
        else: ""

    String.trim_trailing("#{planet}#{moon} - #{corp}#{operation}")
  end

  # Solo tipos publicados con grupo de mercado (≈ 19.500 de 53.000). Cada línea trae
  # descripciones en 8 idiomas: antes de decodificar se descartan las que no mencionan
  # marketGroupID (no depende del formato del JSON); `published` se valida ya decodificado.
  # sobelow_skip ["Traversal.FileModule"]
  defp types(dir) do
    dir
    |> Path.join("types.jsonl")
    |> File.stream!(:line)
    |> Stream.filter(&String.contains?(&1, "marketGroupID"))
    |> Stream.map(&Jason.decode!/1)
    |> Stream.filter(&(&1["published"] == true and is_integer(&1["marketGroupID"])))
    |> Map.new(fn t ->
      {t["_key"],
       %{
         name: en(t["name"]),
         name_es: get_in(t, ["name", "es"]) || en(t["name"]),
         group_id: t["groupID"],
         market_group_id: t["marketGroupID"],
         volume: (t["volume"] || 0) / 1,
         packaged_volume: (t["packagedVolume"] || t["volume"] || 0) / 1,
         capacity: (t["capacity"] || 0) / 1
       }}
    end)
  end

  # Adyacencia por stargates: sistema => [sistemas destino].
  defp neighbors(stargates) do
    Enum.reduce(stargates, %{}, fn gate, acc ->
      from = gate["solarSystemID"]
      to = get_in(gate, ["destination", "solarSystemID"])
      Map.update(acc, from, [to], &[to | &1])
    end)
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp stream(dir, file) do
    dir
    |> Path.join(file <> ".jsonl")
    |> File.stream!(:line)
    |> Stream.map(&Jason.decode!/1)
  end

  defp en(%{"en" => name}), do: name
  defp en(_other), do: nil

  @romans [{10, "X"}, {9, "IX"}, {5, "V"}, {4, "IV"}, {1, "I"}]

  @doc false
  @spec roman(pos_integer()) :: String.t()
  def roman(0), do: ""

  def roman(n) when n > 0 do
    {value, letters} = Enum.find(@romans, fn {v, _} -> n >= v end)
    letters <> roman(n - value)
  end
end
