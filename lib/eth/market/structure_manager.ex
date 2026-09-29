defmodule Eth.Market.StructureManager do
  @moduledoc """
  Administra los mercados de estructuras (RF-1.6):

  - cada `:structures_refresh_ms` sincroniza la lista pública de ESI y resuelve nombre,
    sistema y región de las estructuras nuevas con el token de un personaje con acceso;
  - arranca un `Eth.Market.StructurePoller` por estructura de la selección
    (`Eth.Market.Structures.selection/0`) y detiene los que ya no corresponden;
  - publica en la ETS pública `eth_structure_access` el acceso de cada personaje, que usa
    la Certeza de acceso (AS-8, ERS §8.9) sin tocar la base en cada consulta.

  En modo Replay no llama a ESI. HTTP y base corren en tareas supervisadas.

  Implementa: RF-1.6, RF-9.6.
  """
  use GenServer

  alias Eth.{Characters, Events, GameRules, Market}
  alias Eth.Esi
  alias Eth.Esi.ServerStatus
  alias Eth.Market.{StructurePoller, Structures}

  @table :eth_structure_access
  @info_scope "esi-universe.read_structures.v1"
  # Tope de resoluciones por ciclo: cada una es un request autenticado.
  @resolve_per_cycle 60

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Pide volver a publicar el acceso (lo llaman los pollers tras cada intento)."
  @spec access_changed() :: :ok
  def access_changed do
    if Process.whereis(__MODULE__), do: GenServer.cast(__MODULE__, :access_changed)
    :ok
  end

  @doc "Pide un ciclo ahora (después de agregar o cambiar estructuras desde Ajustes)."
  @spec refresh() :: :ok
  def refresh do
    if Process.whereis(__MODULE__), do: send(__MODULE__, :cycle)
    :ok
  end

  @doc """
  Acceso a una estructura: `%{public: boolean, access: %{character_id => "ok" | ...}}`
  (`nil` si no está registrada).
  """
  @spec access(pos_integer()) :: map() | nil
  def access(structure_id) do
    case :ets.whereis(@table) do
      :undefined ->
        nil

      table ->
        case :ets.lookup(table, structure_id) do
          [{_id, access}] -> access
          [] -> nil
        end
    end
  end

  ## Callbacks

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    send(self(), :cycle)
    {:ok, %{task: nil, pollers: MapSet.new()}}
  end

  @impl true
  def handle_cast(:access_changed, state) do
    publish_access()
    {:noreply, state}
  end

  @impl true
  def handle_info(:cycle, %{task: %Task{}} = state), do: {:noreply, state}

  def handle_info(:cycle, state) do
    Process.send_after(self(), :cycle, GameRules.get(:structures_refresh_ms))

    if Market.data_source() == :live and not ServerStatus.downtime?() do
      task = Task.Supervisor.async_nolink(Eth.Market.TaskSupervisor, &sync/0)
      {:noreply, %{state | task: task}}
    else
      {:noreply, apply_selection(state)}
    end
  end

  def handle_info({ref, _result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, apply_selection(%{state | task: nil})}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    Events.emit(:warning, "Estructuras", "Falló la sincronización: #{inspect(reason)}")
    {:noreply, apply_selection(%{state | task: nil})}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  ## Sincronización (en la tarea)

  defp sync do
    case Esi.public_market_structures() do
      {:ok, %{body: ids}} when is_list(ids) -> Structures.sync_public(ids)
      _error -> :ok
    end

    resolve(Enum.take(Structures.unresolved(), @resolve_per_cycle))
  end

  # Nombre, sistema y región con el token de algún personaje con el scope.
  defp resolve([]), do: :ok

  defp resolve(structures) do
    case token() do
      nil ->
        :ok

      {character_id, token} ->
        Enum.each(structures, &resolve_one(&1, character_id, token))
    end
  end

  defp resolve_one(structure, character_id, token) do
    case Esi.structure(structure.id, character_id, token) do
      {:ok, %{body: info}} ->
        Structures.put_info(structure.id, info)

      {:error, {:http, %{status: 403}}} ->
        Structures.put_access(structure.id, character_id, :forbidden, "HTTP 403 (datos)")

      _error ->
        :ok
    end
  end

  defp token do
    Characters.list()
    |> Enum.filter(&(&1.token_status == "ok" and @info_scope in (&1.scopes || [])))
    |> Enum.find_value(fn c ->
      case Structures.character_token(c.id) do
        {:ok, token} -> {c.id, token}
        _error -> nil
      end
    end)
  end

  ## Selección y pollers

  defp apply_selection(state) do
    selection = Structures.selection()
    wanted = MapSet.new(selection, & &1.id)

    for s <- selection, not MapSet.member?(state.pollers, s.id) do
      DynamicSupervisor.start_child(Eth.Market.StructureSupervisor, {StructurePoller, s})
    end

    for id <- state.pollers, not MapSet.member?(wanted, id) do
      case Registry.lookup(Eth.Market.Registry, {:structure, id}) do
        [{pid, _}] -> DynamicSupervisor.terminate_child(Eth.Market.StructureSupervisor, pid)
        [] -> :ok
      end
    end

    publish_access()
    %{state | pollers: wanted}
  end

  defp publish_access do
    access = Structures.access_map()

    rows =
      for s <- Structures.list() do
        per_character =
          for {{sid, cid}, a} <- access, sid == s.id, into: %{}, do: {cid, a.status}

        {s.id, %{public: s.public_market, name: s.name, access: per_character}}
      end

    :ets.delete_all_objects(@table)
    :ets.insert(@table, rows)
  end
end
