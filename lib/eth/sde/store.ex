defmodule Eth.Sde.Store do
  @moduledoc """
  Ciclo de vida del SDE y del grafo de ruteo (RF-2.1, RF-2.4).

  1. Al arrancar carga el SDE procesado + grafo desde la caché en disco
     (`sde/processed-<build>.etf`), si existe.
  2. Si no hay caché: descarga el zip del último build, lo procesa, construye el grafo,
     guarda la caché y borra los temporales.
  3. Cada `:sde_check_interval_ms` consulta el último build; si hay uno nuevo, repite 2 y
     reemplaza los datos **en caliente**, sin reiniciar.

  Los datos se publican en `:persistent_term` (lectura sin copia desde cualquier proceso;
  solo cambian con un build nuevo). El estado se publica en `sde:status`.

  Implementa: RF-2.1, RF-2.2, RF-2.4, RNF-15.3.
  """
  use GenServer

  require Logger

  alias Eth.{Clock, Esi, Events, GameRules, Storage}
  alias Eth.Routing.Graph
  alias Eth.Sde.{Download, Processor}

  @status_table :eth_sde_status
  @topic "sde:status"
  @retry_ms 600_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Tópico PubSub del estado del SDE."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "Estado actual (`:loading`, `:downloading`, `:processing`, `:ready`, `:error`)."
  @spec status() :: map()
  def status do
    if :ets.whereis(@status_table) != :undefined do
      case :ets.lookup(@status_table, :status) do
        [{:status, status}] -> status
        [] -> %{state: :loading}
      end
    else
      %{state: :stopped}
    end
  end

  @impl true
  def init(_opts) do
    :ets.new(@status_table, [:named_table, :public, :set, read_concurrency: true])
    set_status(%{state: :loading})
    {:ok, %{build: nil}, {:continue, :load}}
  end

  @impl true
  def handle_continue(:load, state) do
    state =
      case load_cache() do
        {:ok, build} -> %{state | build: build}
        :none -> refresh(state)
      end

    Process.send_after(self(), :check, GameRules.get(:sde_check_interval_ms))
    {:noreply, state}
  end

  @impl true
  def handle_info(:check, state) do
    state =
      case Download.latest_build() do
        {:ok, %{build: build}} when build != state.build -> refresh(state)
        _ -> state
      end

    Process.send_after(self(), :check, GameRules.get(:sde_check_interval_ms))
    {:noreply, state}
  end

  def handle_info(:retry, state), do: {:noreply, refresh(state)}

  ## Carga desde caché

  # Rutas: Storage.path("sde") + nombres con el build entero; nunca entrada externa.
  # sobelow_skip ["Traversal.FileModule"]
  defp load_cache do
    dir = Storage.path("sde")

    case dir
         |> Path.join("processed-*.etf")
         |> Path.wildcard()
         |> Enum.max_by(&build_of/1, fn -> nil end) do
      nil ->
        :none

      file ->
        started = System.monotonic_time(:millisecond)
        cache = file |> File.read!() |> Plug.Crypto.non_executable_binary_to_term()
        publish(cache, System.monotonic_time(:millisecond) - started, :cache)
        {:ok, cache.meta.build}
    end
  rescue
    error ->
      Logger.warning("Caché del SDE ilegible, se descarga de nuevo: #{Exception.message(error)}")
      :none
  end

  ## Descarga y procesamiento

  # sobelow_skip ["Traversal.FileModule"]
  defp refresh(state) do
    started = System.monotonic_time(:millisecond)
    dir = Storage.path("sde")

    with {:ok, %{build: build, release_date: release}} <- Download.latest_build(),
         _ = set_status(%{state: :downloading, build: build}),
         zip = Path.join(dir, "sde-#{build}.zip"),
         :ok <- ensure_zip(build, zip),
         _ = set_status(%{state: :processing, build: build}),
         extract_dir = Path.join(dir, "extract-#{build}"),
         :ok <- Processor.extract(zip, extract_dir) do
      data = Processor.process(extract_dir, &resolve_station_names/1)
      graph = Graph.build(data.systems, graph_opts())
      meta = %{build: build, release_date: release, processed_at: Clock.utc_now()}
      cache = %{meta: meta, data: data, graph: graph}

      File.write!(
        Path.join(dir, "processed-#{build}.etf"),
        :erlang.term_to_binary(cache, compressed: 6)
      )

      cleanup(dir, build)
      publish(cache, System.monotonic_time(:millisecond) - started, :download)
      %{state | build: build}
    else
      error -> fail(state, error)
    end
  rescue
    error -> fail(state, {:exception, Exception.message(error)})
  end

  defp ensure_zip(build, zip) do
    if File.exists?(zip), do: :ok, else: Download.zip(build, zip)
  end

  defp fail(state, error) do
    message = "No se pudo actualizar el SDE: #{inspect(error)}"
    Events.emit(:error, "SDE", message)

    # Si ya hay datos cargados, se siguen usando; si no, se reintenta.
    if state.build do
      set_status(Map.merge(status(), %{state: :ready, last_error: message}))
    else
      set_status(%{state: :error, error: message})
      Process.send_after(self(), :retry, @retry_ms)
    end

    state
  end

  # Nombres exactos de estaciones vía ESI (6 requests de 1.000 IDs). Si ESI no responde,
  # el procesador compone los nombres con la regla del cliente.
  defp resolve_station_names(ids) do
    ids
    |> Enum.chunk_every(1000)
    |> Enum.reduce(%{}, fn chunk, acc ->
      case Esi.names(chunk) do
        {:ok, %{body: names}} -> Enum.into(names, acc, &{&1["id"], &1["name"]})
        _error -> acc
      end
    end)
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp cleanup(dir, build) do
    File.rm_rf!(Path.join(dir, "extract-#{build}"))
    File.rm(Path.join(dir, "sde-#{build}.zip"))

    for file <- Path.wildcard(Path.join(dir, "processed-*.etf")), build_of(file) != build do
      File.rm(file)
    end
  end

  defp build_of(file) do
    case Regex.run(~r/processed-(\d+)\.etf$/, file) do
      [_, build] -> String.to_integer(build)
      _ -> 0
    end
  end

  defp graph_opts do
    [
      root: GameRules.get(:route_root_system_id),
      excluded_region_ids: GameRules.get(:excluded_route_region_ids),
      highsec_min: GameRules.get(:highsec_min_security)
    ]
  end

  ## Publicación

  defp publish(%{meta: meta, data: data, graph: graph}, duration_ms, origin) do
    :persistent_term.put({Eth.Sde, :data}, data)
    :persistent_term.put({Eth.Sde, :meta}, meta)
    :persistent_term.put({Eth.Routing, :graph}, graph)

    status = %{
      state: :ready,
      build: meta.build,
      release_date: meta.release_date,
      systems: map_size(data.systems),
      stations: map_size(data.stations),
      types: map_size(data.types),
      routable_systems: graph.n,
      duration_ms: duration_ms,
      origin: origin
    }

    set_status(status)

    source = if origin == :cache, do: "caché", else: "descarga"

    Events.emit(
      :info,
      "SDE",
      "Build #{meta.build} listo desde #{source} en #{div(duration_ms, 1000)} s: " <>
        "#{graph.n} sistemas ruteables, #{status.stations} estaciones, #{status.types} tipos de mercado"
    )
  end

  defp set_status(status) do
    :ets.insert(@status_table, {:status, status})
    Phoenix.PubSub.broadcast(Eth.PubSub, @topic, {:sde_status, status})
    status
  end
end
