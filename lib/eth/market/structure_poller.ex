defmodule Eth.Market.StructurePoller do
  @moduledoc """
  Proceso por estructura seguida que mantiene su snapshot de órdenes (RF-1.6).

  - Descarga con el token de un personaje con el scope de mercados de estructuras. Prueba
    primero los que ya tienen acceso, después los que nunca se probaron; nunca uno con un
    403 de hace menos de 24 h (CA de RF-1.6).
  - Un 403 marca `forbidden` para ese personaje y pasa al siguiente; sin candidatos queda
    `:no_access` y vuelve a mirar en `@no_access_ms`.
  - El próximo ciclo se programa en `Expires + jitter` (RNF-3.3); en el downtime espera.
  - La descarga corre en una tarea supervisada.

  Implementa: RF-1.6, RNF-3.3.
  """
  use GenServer

  alias Eth.{Characters, Clock, Events, GameRules}
  alias Eth.Esi.{Budget, ServerStatus}
  alias Eth.Market.{Fetcher, RegionPoller, StructureManager, Structures}

  @scope "esi-markets.structure_markets.v1"
  @no_access_ms 3_600_000

  defstruct [:structure, :task, :character_id, :next_at, :last_error, status: :idle, failures: 0]

  @spec start_link(Eth.Market.Structure.t()) :: GenServer.on_start()
  def start_link(structure),
    do: GenServer.start_link(__MODULE__, structure, name: via(structure.id))

  @spec child_spec(Eth.Market.Structure.t()) :: Supervisor.child_spec()
  def child_spec(structure) do
    %{
      id: {__MODULE__, structure.id},
      start: {__MODULE__, :start_link, [structure]},
      restart: :transient
    }
  end

  @doc "Estado público del poller (Ajustes y Centro de control)."
  @spec status(pos_integer()) :: map()
  def status(id), do: GenServer.call(via(id), :status)

  defp via(id), do: {:via, Registry, {Eth.Market.Registry, {:structure, id}}}

  @impl true
  def init(structure) do
    state = %__MODULE__{structure: structure}
    {:ok, schedule(state, Enum.random(0..10_000))}
  end

  @impl true
  def handle_call(:status, _from, state) do
    reply = %{
      id: state.structure.id,
      status: state.status,
      character_id: state.character_id,
      next_at: state.next_at,
      last_error: state.last_error
    }

    {:reply, reply, state}
  end

  @impl true
  def handle_info(:tick, %{task: %Task{}} = state), do: {:noreply, state}

  def handle_info(:tick, state) do
    cond do
      ServerStatus.downtime?() ->
        until = ServerStatus.window_end(Clock.utc_now())
        {:noreply, schedule(state, Clock.ms_until(until) + jitter())}

      match?({:error, _}, Budget.check()) ->
        {:error, {_kind, until}} = Budget.check()
        {:noreply, schedule(state, Clock.ms_until(until) + jitter())}

      true ->
        {:noreply, start_fetch(state)}
    end
  end

  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, handle_result(result, %{state | task: nil})}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    {:noreply, handle_result({:error, {:crash, reason}}, %{state | task: nil})}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  ## Descarga

  defp start_fetch(state) do
    case pick_character(state.structure.id) do
      nil ->
        %{state | status: :no_access, character_id: nil} |> schedule(@no_access_ms)

      {character_id, token} ->
        %{id: id, solar_system_id: system_id} = state.structure

        task =
          Task.Supervisor.async_nolink(Eth.Market.TaskSupervisor, fn ->
            Fetcher.fetch_structure(id, system_id, character_id, token)
          end)

        %{state | task: task, status: :fetching, character_id: character_id}
    end
  end

  # Personajes con el scope y sesión vigente, sin un 403 reciente para esta estructura:
  # primero los que ya tienen acceso comprobado.
  defp pick_character(structure_id) do
    now = Clock.utc_now()
    access = Structures.access_map()

    Characters.list()
    |> Enum.filter(&(&1.token_status == "ok" and @scope in (&1.scopes || [])))
    |> Enum.filter(&Structures.may_try?(access[{structure_id, &1.id}], now))
    |> Enum.sort_by(&if(match?(%{status: "ok"}, access[{structure_id, &1.id}]), do: 0, else: 1))
    |> Enum.find_value(fn character ->
      case Structures.character_token(character.id) do
        {:ok, token} -> {character.id, token}
        _error -> nil
      end
    end)
  end

  defp handle_result({:ok, meta}, state) do
    Structures.put_access(state.structure.id, state.character_id, :ok)
    Structures.put_orders_count(state.structure.id, meta.orders)
    StructureManager.access_changed()

    %{state | status: :cached, failures: 0, last_error: nil}
    |> schedule(Clock.ms_until(meta.expires) + jitter())
  end

  # Sin acceso para este personaje: se registra y se prueba enseguida con el siguiente.
  defp handle_result({:error, {:http, status}}, state) when status in [401, 403] do
    Structures.put_access(state.structure.id, state.character_id, :forbidden, "HTTP #{status}")
    StructureManager.access_changed()

    Events.emit(
      :warning,
      "Estructuras",
      "Sin acceso a #{name(state)} con el personaje #{state.character_id} (HTTP #{status})"
    )

    schedule(%{state | status: :idle}, 0)
  end

  defp handle_result({:error, {kind, until}}, state) when kind in [:paused, :rate_limited] do
    schedule(%{state | status: :rate_limited}, Clock.ms_until(until) + jitter())
  end

  defp handle_result({:error, reason}, state) do
    failures = state.failures + 1
    delay = RegionPoller.backoff_ms(failures)
    message = inspect(reason)

    if failures in [1, GameRules.get(:circuit_breaker_failures)] do
      Events.emit(
        :warning,
        "Estructuras",
        "#{name(state)}: #{message} · reintento en #{div(delay, 1000)} s"
      )
    end

    %{state | status: :backoff, failures: failures, last_error: message} |> schedule(delay)
  end

  defp name(state), do: state.structure.name || "Estructura #{state.structure.id}"

  defp jitter, do: Enum.random(GameRules.get(:poll_jitter_ms))

  defp schedule(state, delay) do
    Process.send_after(self(), :tick, delay)
    %{state | next_at: DateTime.add(Clock.utc_now(), delay, :millisecond)}
  end
end
