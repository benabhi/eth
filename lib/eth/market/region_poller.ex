defmodule Eth.Market.RegionPoller do
  @moduledoc """
  Proceso por región que mantiene su snapshot de órdenes al día (RF-1.3).

  Estados: `:idle` (esperando `Expires`), `:fetching` (descargando), `:cached` (snapshot
  vigente), `:backoff` (error, con reintento exponencial y circuit breaker),
  `:rate_limited` (presupuesto o error limit) y `:paused` (manual o downtime).

  - El próximo ciclo se programa en `Expires + jitter`, **nunca antes** (RNF-3.3).
  - La descarga corre en una tarea supervisada: el proceso nunca se bloquea y puede
    responder su estado mientras descarga.
  - El nivel de la región y el presupuesto restante deciden si se descarga en cada ciclo
    (`Eth.Market.Policy`).
  - Cada cambio de estado se publica en `market:status`.

  Implementa: RF-1.2, RF-1.3, RF-1.7, RF-1.8, RF-8.8.
  """
  use GenServer

  alias Eth.{Clock, Events, GameRules}
  alias Eth.Esi.{Budget, ServerStatus}
  alias Eth.Market.{Fetcher, Policy, TableOwner}

  @topic "market:status"
  @history_size 20
  @default_cycle_ms 300_000
  @initial_stagger_ms 20_000

  @type status :: :idle | :fetching | :cached | :backoff | :rate_limited | :paused

  defstruct [
    :region_id,
    :name,
    :timer,
    :task,
    :next_at,
    :progress,
    :last_error,
    :pause_reason,
    status: :idle,
    failures: 0,
    skipped: 0,
    history: []
  ]

  ## API

  @spec start_link({pos_integer(), String.t()}) :: GenServer.on_start()
  def start_link({region_id, name}) do
    GenServer.start_link(__MODULE__, {region_id, name}, name: via(region_id))
  end

  @spec child_spec({pos_integer(), String.t()}) :: Supervisor.child_spec()
  def child_spec({region_id, _name} = arg) do
    %{id: {__MODULE__, region_id}, start: {__MODULE__, :start_link, [arg]}}
  end

  @doc "Tópico PubSub de estados de pollers."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "Estado público del poller (para el Centro de control)."
  @spec status(pos_integer()) :: map()
  def status(region_id), do: GenServer.call(via(region_id), :status)

  @doc """
  Descarga ahora, solo si ESI ya tiene datos nuevos (`Expires` vencido) o si la región
  está en error. Nunca elude la caché de ESI (RF-8.8).
  """
  @spec refresh_now(pos_integer()) :: :ok | {:error, :not_expired | :busy | :paused}
  def refresh_now(region_id), do: GenServer.call(via(region_id), :refresh_now)

  @doc "Pausa manual de la región."
  @spec pause(pos_integer()) :: :ok
  def pause(region_id), do: GenServer.call(via(region_id), :pause)

  @doc "Reanuda una región pausada a mano."
  @spec resume(pos_integer()) :: :ok
  def resume(region_id), do: GenServer.call(via(region_id), :resume)

  defp via(region_id), do: {:via, Registry, {Eth.Market.Registry, region_id}}

  ## Callbacks

  @impl true
  def init({region_id, name}) do
    state = %__MODULE__{region_id: region_id, name: name}
    {:ok, schedule(state, initial_delay(region_id))}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, public_status(state), state}

  def handle_call(:refresh_now, _from, %{status: :fetching} = state),
    do: {:reply, {:error, :busy}, state}

  def handle_call(:refresh_now, _from, %{status: :paused} = state),
    do: {:reply, {:error, :paused}, state}

  def handle_call(:refresh_now, _from, state) do
    if refreshable?(state) do
      Events.emit(:action, "Usuario", "Actualización manual de #{state.name}")
      {:reply, :ok, schedule(%{state | failures: 0, skipped: 0}, 0)}
    else
      {:reply, {:error, :not_expired}, state}
    end
  end

  def handle_call(:pause, _from, state) do
    Events.emit(:action, "Usuario", "Pausa de la región #{state.name}")
    state = cancel_timer(state)
    {:reply, :ok, broadcast(%{state | status: :paused, pause_reason: :manual, next_at: nil})}
  end

  # Reanudar respeta Expires: si el snapshot vigente todavía no venció, espera (RNF-3.3).
  def handle_call(:resume, _from, state) do
    Events.emit(:action, "Usuario", "Reanudación de la región #{state.name}")
    delay = next_cycle_delay(state.region_id)
    {:reply, :ok, schedule(%{state | status: :idle, pause_reason: nil}, delay)}
  end

  @impl true
  def handle_info(:tick, %{status: :paused, pause_reason: :manual} = state),
    do: {:noreply, state}

  def handle_info(:tick, %{status: :fetching} = state), do: {:noreply, state}

  def handle_info(:tick, state), do: {:noreply, tick(%{state | timer: nil})}

  def handle_info({:fetch_progress, _region_id, done, total}, state) do
    {:noreply, broadcast(%{state | progress: {done, total}})}
  end

  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, handle_result(result, %{state | task: nil, progress: nil})}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    {:noreply, handle_result({:error, {:crash, reason}}, %{state | task: nil, progress: nil})}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  ## Ciclo

  # Orden de decisión: downtime → presupuesto/pausa de ESI → política por nivel → descarga.
  defp tick(state) do
    if ServerStatus.downtime?() do
      until = ServerStatus.window_end(Clock.utc_now())
      delay = Clock.ms_until(until) + Enum.random(0..60_000)
      state |> set(:paused, pause_reason: :downtime) |> schedule(delay)
    else
      case Budget.check(GameRules.get(:market_budget_group)) do
        {:error, {_kind, until}} ->
          state |> set(:rate_limited) |> schedule(Clock.ms_until(until) + jitter())

        :ok ->
          maybe_fetch(state)
      end
    end
  end

  defp maybe_fetch(state) do
    if Policy.fetch?(tier(state), budget_ratio(), state.skipped) do
      start_fetch(state)
    else
      %{state | skipped: state.skipped + 1} |> schedule(@default_cycle_ms)
    end
  end

  defp start_fetch(state) do
    region_id = state.region_id
    poller = self()

    task =
      Task.Supervisor.async_nolink(Eth.Market.TaskSupervisor, fn ->
        Fetcher.fetch(region_id, poller)
      end)

    broadcast(%{
      state
      | task: task,
        status: :fetching,
        skipped: 0,
        progress: {0, nil},
        next_at: nil
    })
  end

  defp handle_result({:ok, meta}, state) do
    entry = %{
      at: Clock.utc_now(),
      duration_ms: meta.duration_ms,
      pages: meta.pages,
      not_modified: meta.not_modified_pages
    }

    state = %{
      state
      | failures: 0,
        last_error: nil,
        history: Enum.take([entry | state.history], @history_size)
    }

    state |> set(:cached) |> schedule(Clock.ms_until(meta.expires) + jitter())
  end

  defp handle_result({:error, {kind, until}}, state) when kind in [:paused, :rate_limited] do
    state |> set(:rate_limited) |> schedule(Clock.ms_until(until) + jitter())
  end

  defp handle_result({:error, reason}, state) do
    failures = state.failures + 1
    delay = backoff_ms(failures)
    message = describe(reason)

    if failures >= GameRules.get(:circuit_breaker_failures) do
      Events.emit(
        :error,
        state.name,
        "#{message} · #{failures} fallos seguidos: circuito abierto"
      )
    else
      Events.emit(
        :warning,
        state.name,
        "#{message} · reintento en #{div(delay, 1000)} s (intento #{failures})"
      )
    end

    %{state | failures: failures, last_error: message} |> set(:backoff) |> schedule(delay)
  end

  @doc false
  @spec backoff_ms(pos_integer()) :: pos_integer()
  def backoff_ms(failures) do
    if failures >= GameRules.get(:circuit_breaker_failures) do
      GameRules.get(:circuit_breaker_open_ms)
    else
      base = GameRules.get(:backoff_base_ms) * Integer.pow(2, failures - 1)
      capped = min(base, GameRules.get(:backoff_max_ms))
      round(capped * (0.8 + :rand.uniform() * 0.4))
    end
  end

  defp describe({:http, status}), do: "HTTP #{status}"
  defp describe({:transport, message}), do: "Error de red: #{message}"
  defp describe(:inconsistent), do: "Páginas inconsistentes entre snapshots de ESI"
  defp describe({:crash, reason}), do: "Fallo inesperado: #{inspect(reason)}"
  defp describe(other), do: inspect(other)

  ## Utilidades

  # "Ignorar backoff" sí; saltarse un rate limit o la caché de ESI, nunca.
  defp refreshable?(%{status: :rate_limited}), do: false

  defp refreshable?(state) do
    state.status == :backoff or
      case TableOwner.current({:region, state.region_id}) do
        nil -> true
        %{meta: %{expires: expires}} -> DateTime.compare(Clock.utc_now(), expires) != :lt
      end
  end

  defp initial_delay(region_id) do
    case TableOwner.current({:region, region_id}) do
      nil -> Enum.random(0..@initial_stagger_ms)
      _snapshot -> next_cycle_delay(region_id)
    end
  end

  # Espera hasta Expires del snapshot vigente (+ jitter); 0 si no hay snapshot.
  defp next_cycle_delay(region_id) do
    case TableOwner.current({:region, region_id}) do
      %{meta: %{expires: expires}} -> Clock.ms_until(expires) + jitter()
      nil -> 0
    end
  end

  defp tier(state) do
    pages =
      case TableOwner.current({:region, state.region_id}) do
        %{meta: %{pages: pages}} -> pages
        nil -> nil
      end

    Policy.tier(state.region_id, pages)
  end

  defp budget_ratio, do: Budget.remaining_ratio(GameRules.get(:market_budget_group))

  defp jitter do
    Enum.random(GameRules.get(:poll_jitter_ms))
  end

  defp set(state, status, opts \\ []) do
    %{state | status: status, pause_reason: Keyword.get(opts, :pause_reason)}
  end

  defp schedule(state, delay_ms) do
    state = cancel_timer(state)
    timer = Process.send_after(self(), :tick, delay_ms)

    broadcast(%{
      state
      | timer: timer,
        next_at: DateTime.add(Clock.utc_now(), delay_ms, :millisecond)
    })
  end

  defp cancel_timer(%{timer: nil} = state), do: state

  defp cancel_timer(%{timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | timer: nil}
  end

  defp broadcast(state) do
    Phoenix.PubSub.broadcast(Eth.PubSub, @topic, {:region_status, public_status(state)})
    state
  end

  defp public_status(state) do
    snapshot = TableOwner.current({:region, state.region_id})
    meta = (snapshot && snapshot.meta) || %{}

    %{
      region_id: state.region_id,
      name: state.name,
      tier: tier(state),
      status: state.status,
      pause_reason: state.pause_reason,
      next_at: state.next_at,
      progress: state.progress,
      failures: state.failures,
      last_error: state.last_error,
      history: state.history,
      generation: snapshot && snapshot.generation,
      orders: meta[:orders],
      sell_orders: meta[:sell_orders],
      buy_orders: meta[:buy_orders],
      pages: meta[:pages],
      bytes: meta[:bytes],
      last_modified: meta[:last_modified],
      expires: meta[:expires],
      not_modified_pages: meta[:not_modified_pages]
    }
  end
end
