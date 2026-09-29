defmodule Eth.Threat.R2Z2 do
  @moduledoc """
  Feed de killmails de zKillboard R2Z2 (RF-3.1, ERS §6.3, RNF-3.6).

  - `sequence.json` da la última secuencia; cada killmail está en `<secuencia>.json`.
  - Ritmo: 100 ms entre éxitos (nunca más de 10 req/s; el límite duro es 15 con baneo de
    1 h), 6 s después de un 404 (todavía no hay datos) y `User-Agent` descriptivo.
  - 403 o 429: el feed se detiene `@banned_ms` y emite un evento crítico.
  - El cursor (última secuencia procesada) se guarda en `app_state` cada
    `@persist_every` kills y al detenerse. Al arrancar continúa desde él si tiene menos de
    24 h (retención de R2Z2); si no, salta a la secuencia más reciente.
  - Cada request corre en una tarea supervisada: el proceso nunca se bloquea.

  Implementa: RF-3.1, RNF-3.6.
  """
  use GenServer

  @behaviour Eth.Threat.KillFeed

  alias Eth.{AppState, Clock, Events}
  alias Eth.Esi.Client
  alias Eth.Market.RegionPoller
  alias Eth.Threat.{Killmail, Radar}

  @cursor_key "r2z2_cursor"
  @success_ms 100
  @not_found_ms 6_000
  @banned_ms 3_600_000
  @retention_s 24 * 3600
  @persist_every 50

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl Eth.Threat.KillFeed
  def status, do: GenServer.call(__MODULE__, :status)

  ## Callbacks

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)

    state = %{
      sequence: nil,
      status: :starting,
      task: nil,
      failures: 0,
      processed: 0,
      unsaved: 0,
      last_ok_at: nil,
      last_kill_at: nil,
      last_uploaded_at: nil,
      banned_until: nil
    }

    {:ok, state, {:continue, :resume}}
  end

  @impl true
  def handle_continue(:resume, state) do
    case AppState.get(@cursor_key) do
      %{"sequence" => seq, "at" => at} when is_integer(seq) ->
        with {:ok, saved_at, _} <- DateTime.from_iso8601(at),
             true <- DateTime.diff(Clock.utc_now(), saved_at) < @retention_s do
          Events.emit(:info, "Radar", "Feed R2Z2: se continúa desde la secuencia #{seq + 1}")
          {:noreply, request(%{state | sequence: seq + 1, status: :live})}
        else
          _ -> {:noreply, request(state)}
        end

      _ ->
        {:noreply, request(state)}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    reply = %{
      source: :r2z2,
      status: state.status,
      sequence: state.sequence,
      processed: state.processed,
      failures: state.failures,
      last_ok_at: state.last_ok_at,
      last_kill_at: state.last_kill_at,
      lag_s: state.last_uploaded_at && DateTime.diff(Clock.utc_now(), state.last_uploaded_at),
      banned_until: state.banned_until
    }

    {:reply, reply, state}
  end

  @impl true
  def handle_info(:next, state), do: {:noreply, request(state)}

  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, handle_result(result, %{state | task: nil})}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    {:noreply, handle_result({:error, {:crash, reason}}, %{state | task: nil})}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    persist(state)
    :ok
  end

  ## Requests (en tareas)

  defp request(%{task: %Task{}} = state), do: state

  defp request(%{sequence: nil} = state) do
    task = Task.Supervisor.async_nolink(Eth.Threat.TaskSupervisor, fn -> latest() end)
    %{state | task: task}
  end

  defp request(%{sequence: seq} = state) do
    task = Task.Supervisor.async_nolink(Eth.Threat.TaskSupervisor, fn -> fetch(seq) end)
    %{state | task: task}
  end

  defp latest do
    case get("/sequence.json") do
      {:ok, %{"sequence" => seq}} when is_integer(seq) -> {:latest, seq}
      {:ok, _other} -> {:error, :invalid_sequence}
      error -> error
    end
  end

  defp fetch(seq) do
    case get("/#{seq}.json") do
      {:ok, body} -> {:killmail, seq, body}
      error -> error
    end
  end

  defp get(path) do
    config = Application.get_env(:eth, __MODULE__, [])

    [
      base_url: Keyword.fetch!(config, :base_url),
      url: path,
      retry: false,
      receive_timeout: 15_000,
      headers: [{"user-agent", user_agent()}]
    ]
    |> Keyword.merge(Keyword.get(config, :req_options, []))
    |> Req.get()
    |> case do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: 404}} ->
        {:error, :not_found}

      {:ok, %Req.Response{status: status}} when status in [403, 429] ->
        {:error, {:banned, status}}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http, status}}

      {:error, exception} ->
        {:error, {:transport, Exception.message(exception)}}
    end
  end

  defp user_agent do
    Client.user_agent(Application.get_env(:eth, Eth.Esi.Client, [])[:contact])
  end

  ## Resultados

  defp handle_result({:latest, seq}, state) do
    Events.emit(:info, "Radar", "Feed R2Z2 conectado en la secuencia #{seq}")
    schedule(%{state | sequence: seq, status: :live, failures: 0}, @success_ms)
  end

  defp handle_result({:killmail, seq, body}, state) do
    now = Clock.utc_now()

    state =
      case Killmail.normalize(body) do
        {:ok, kill} ->
          Radar.ingest(kill)
          %{state | last_kill_at: now}

        _npc_or_invalid ->
          state
      end

    uploaded = body["uploaded_at"] && DateTime.from_unix!(body["uploaded_at"])

    state =
      %{
        state
        | sequence: seq + 1,
          status: :live,
          failures: 0,
          processed: state.processed + 1,
          unsaved: state.unsaved + 1,
          last_ok_at: now,
          last_uploaded_at: uploaded || state.last_uploaded_at
      }
      |> maybe_persist()

    schedule(state, @success_ms)
  end

  # Todavía no hay una kill con esa secuencia: se reintenta la misma más tarde.
  defp handle_result({:error, :not_found}, state) do
    schedule(%{state | status: :waiting, failures: 0, last_ok_at: Clock.utc_now()}, @not_found_ms)
  end

  defp handle_result({:error, {:banned, status}}, state) do
    until = DateTime.add(Clock.utc_now(), @banned_ms, :millisecond)

    Events.emit(
      :error,
      "Radar",
      "R2Z2 respondió #{status}: feed detenido 1 h para no prolongar el bloqueo"
    )

    schedule(%{state | status: :banned, banned_until: until}, @banned_ms)
  end

  defp handle_result({:error, reason}, state) do
    failures = state.failures + 1
    delay = max(RegionPoller.backoff_ms(failures), @not_found_ms)

    if failures in [1, 5] do
      Events.emit(
        :warning,
        "Radar",
        "Feed R2Z2: #{inspect(reason)} · reintento en #{div(delay, 1000)} s"
      )
    end

    schedule(%{state | status: :error, failures: failures}, delay)
  end

  defp schedule(state, delay) do
    Process.send_after(self(), :next, delay)
    state
  end

  ## Cursor (RF-3.1)

  defp maybe_persist(%{unsaved: n} = state) when n >= @persist_every, do: persist(state)
  defp maybe_persist(state), do: state

  defp persist(%{sequence: nil} = state), do: state

  defp persist(state) do
    AppState.put(@cursor_key, %{
      "sequence" => state.sequence - 1,
      "at" => DateTime.to_iso8601(Clock.utc_now())
    })

    %{state | unsaved: 0}
  rescue
    # Sin base de datos (p. ej. al apagar) se pierde como mucho el último lote.
    _error -> state
  end
end
