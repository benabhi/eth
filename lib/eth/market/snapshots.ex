defmodule Eth.Market.Snapshots do
  @moduledoc """
  Persistencia en disco de snapshots de órdenes (RF-1.10, RF-1.11).

  Cada región se guarda como dos archivos en el directorio de datos:
  `region_<id>.ets` (la tabla, con `:ets.tab2file/2`) y `region_<id>.meta` (metadatos,
  incluidos los ETag por página para que el primer ciclo tras reiniciar pueda usar 304).
  Se escribe en archivos temporales y se renombra, así un corte a mitad de escritura
  nunca deja un snapshot corrupto.

  Directorios (dentro de `:data_dir`): `snapshots/` para el reinicio en caliente y
  `replay/` para el modo Replay.

  Implementa: RF-1.10, RF-1.11, RNF-2.6.
  """

  alias Eth.Market.TableOwner

  @doc "Directorio de un tipo de snapshot (`:snapshots` o `:replay`)."
  @spec dir(:snapshots | :replay) :: Path.t()
  def dir(kind) when kind in [:snapshots, :replay],
    do: Path.join(data_dir(), Atom.to_string(kind))

  @doc "Directorio base de datos regenerables (volumen de datos, nunca en git)."
  @spec data_dir() :: Path.t()
  def data_dir,
    do: Application.get_env(:eth, :data_dir) || Path.join(:code.priv_dir(:eth), "data")

  # Las rutas se arman solo con el directorio de datos configurado y un region_id entero
  # (guard is_integer), nunca con entrada externa: se omite la regla de traversal de
  # Sobelow en las funciones que tocan archivos.

  @doc "Guarda el snapshot vigente de una región."
  @spec save(pos_integer(), String.t(), TableOwner.entry(), Path.t()) :: :ok | {:error, term()}
  # sobelow_skip ["Traversal.FileModule"]
  def save(region_id, name, %{tid: tid, meta: meta}, dir) when is_integer(region_id) do
    File.mkdir_p!(dir)
    {table, meta_file} = paths(region_id, dir)

    with :ok <- :ets.tab2file(tid, String.to_charlist(table <> ".tmp")),
         :ok <- File.write(meta_file <> ".tmp", encode_meta(Map.put(meta, :name, name))),
         :ok <- File.rename(table <> ".tmp", table) do
      File.rename(meta_file <> ".tmp", meta_file)
    end
  end

  @doc "Guarda todos los snapshots vigentes. `names` mapea `region_id => nombre`."
  @spec save_all(%{pos_integer() => String.t()}, Path.t()) :: non_neg_integer()
  def save_all(names, dir) do
    for {{:region, id}, entry} <- TableOwner.all(),
        save(id, Map.get(names, id, "Región #{id}"), entry, dir) == :ok,
        reduce: 0,
        do: (count -> count + 1)
  end

  @doc """
  Carga el snapshot de una región en una tabla nueva, **propiedad del proceso llamador**
  (para publicarla después con `TableOwner.publish/3`).
  """
  @spec load(pos_integer(), Path.t()) :: {:ok, :ets.tid(), map()} | :error
  # sobelow_skip ["Traversal.FileModule"]
  def load(region_id, dir) when is_integer(region_id) do
    {table, meta_file} = paths(region_id, dir)

    with {:ok, binary} <- File.read(meta_file),
         meta when is_map(meta) <- decode_meta(binary),
         {:ok, tid} <- :ets.file2tab(String.to_charlist(table)) do
      {:ok, tid, meta}
    else
      _ -> :error
    end
  end

  @doc "Metadatos guardados de una región, sin cargar la tabla."
  @spec read_meta(pos_integer(), Path.t()) :: map() | nil
  # sobelow_skip ["Traversal.FileModule"]
  def read_meta(region_id, dir) when is_integer(region_id) do
    {_table, meta_file} = paths(region_id, dir)

    case File.read(meta_file) do
      {:ok, binary} -> decode_meta(binary)
      _ -> nil
    end
  end

  @doc "Regiones con snapshot guardado en `dir`, como `[{region_id, nombre}]`."
  @spec list(Path.t()) :: [{pos_integer(), String.t()}]
  def list(dir) do
    dir
    |> Path.join("region_*.meta")
    |> Path.wildcard()
    |> Enum.flat_map(fn file ->
      with [_, id] <- Regex.run(~r/region_(\d+)\.meta$/, file),
           id = String.to_integer(id),
           %{name: name} <- read_meta(id, dir) do
        [{id, name}]
      else
        _ -> []
      end
    end)
    |> Enum.sort_by(&elem(&1, 1))
  end

  defp paths(region_id, dir) do
    base = Path.join(dir, "region_#{region_id}")
    {base <> ".ets", base <> ".meta"}
  end

  # Metadatos serializados solo con strings y números: al decodificar con `:safe` no hace
  # falta que existan átomos (al arrancar, en dev, los módulos que los definen todavía no
  # están cargados y `:safe` fallaría). Las claves se reconstruyen desde esta lista.
  @meta_keys ~w(name last_modified expires pages page_etags orders sell_orders buy_orders
                bytes not_modified_pages duration_ms)a

  @doc false
  @spec encode_meta(map()) :: binary()
  def encode_meta(meta) do
    for key <- @meta_keys, Map.has_key?(meta, key), into: %{} do
      {Atom.to_string(key), encode_value(Map.fetch!(meta, key))}
    end
    |> :erlang.term_to_binary()
  end

  @doc false
  @spec decode_meta(binary()) :: map() | nil
  def decode_meta(binary) do
    raw = Plug.Crypto.non_executable_binary_to_term(binary, [:safe])

    for key <- @meta_keys, Map.has_key?(raw, Atom.to_string(key)), into: %{} do
      {key, decode_value(key, Map.fetch!(raw, Atom.to_string(key)))}
    end
  rescue
    _error -> nil
  end

  defp encode_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp encode_value(value), do: value

  defp decode_value(key, value) when key in [:last_modified, :expires] do
    {:ok, dt, 0} = DateTime.from_iso8601(value)
    dt
  end

  defp decode_value(_key, value), do: value
end
