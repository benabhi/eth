defmodule Eth.Market.Prices do
  @moduledoc """
  Precios de referencia globales de `/markets/prices` (RF-1.9): `average_price` y
  `adjusted_price` por tipo. Se usan en el pre-filtro anti-scam (AS-3) y para estimar el
  valor de la carga cuando no hay historial.

  - Una sola descarga (sin paginar); la siguiente, en `Expires + jitter`, con
    `If-None-Match` (RNF-3.3).
  - La descarga corre en una tarea supervisada: el proceso nunca se bloquea.
  - Durante el downtime espera al final de la ventana; ante un error reintenta con el
    backoff de los pollers.
  - Persiste la última lista en el directorio de datos: tras un reinicio (o en modo Replay,
    que no llama a ESI) se usa la guardada.

  La tabla ETS `eth_prices` (`type_id → {average, adjusted}`) es pública: los lectores no
  pasan por este proceso.

  Implementa: RF-1.9, RF-1.10, RF-1.11.
  """
  use GenServer

  alias Eth.{Clock, Events, GameRules, Market, Storage}
  alias Eth.Esi
  alias Eth.Esi.ServerStatus
  alias Eth.Market.RegionPoller

  @table :eth_prices
  @file_name "prices.etf"

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Precio promedio global de un tipo (`nil` si no se conoce)."
  @spec average(pos_integer()) :: float() | nil
  def average(type_id) do
    case lookup(type_id) do
      {average, _adjusted} -> average
      nil -> nil
    end
  end

  @doc "Precio ajustado global de un tipo (`nil` si no se conoce)."
  @spec adjusted(pos_integer()) :: float() | nil
  def adjusted(type_id) do
    case lookup(type_id) do
      {_average, adjusted} -> adjusted
      nil -> nil
    end
  end

  defp lookup(type_id) do
    case :ets.whereis(@table) do
      :undefined ->
        nil

      table ->
        case :ets.lookup(table, type_id) do
          [{^type_id, average, adjusted}] -> {average, adjusted}
          [] -> nil
        end
    end
  end

  @doc """
  Convierte la respuesta de ESI en filas `{type_id, average, adjusted}`. Los tipos sin
  `average_price` (nunca comerciados) quedan con `nil`.
  """
  @spec parse([map()]) :: [{pos_integer(), float() | nil, float() | nil}]
  def parse(body) when is_list(body) do
    for %{"type_id" => type_id} = item <- body do
      {type_id, to_float(item["average_price"]), to_float(item["adjusted_price"])}
    end
  end

  defp to_float(nil), do: nil
  defp to_float(value), do: value / 1

  ## Callbacks

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    # Restaurar en init (una lectura de archivo): los precios están disponibles apenas
    # arranca el proceso.
    state = restore(%{etag: nil, expires: nil, task: nil, timer: nil, failures: 0})

    if Market.data_source() == :live,
      do: {:ok, schedule(state, next_delay(state))},
      else: {:ok, state}
  end

  @impl true
  def handle_info(:tick, %{task: %Task{}} = state), do: {:noreply, state}

  def handle_info(:tick, state) do
    state = %{state | timer: nil}

    if ServerStatus.downtime?() do
      until = ServerStatus.window_end(Clock.utc_now())
      {:noreply, schedule(state, Clock.ms_until(until) + jitter())}
    else
      etag = state.etag
      task = Task.Supervisor.async_nolink(Eth.Market.TaskSupervisor, fn -> fetch(etag) end)
      {:noreply, %{state | task: task}}
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

  # Corre en la tarea.
  defp fetch(etag) do
    case Esi.market_prices(etag) do
      {:ok, %{status: 304} = resp} -> {:not_modified, resp.expires}
      {:ok, resp} -> {:ok, parse(resp.body), resp.etag, resp.expires}
      {:error, reason} -> {:error, reason}
    end
  end

  defp handle_result({:ok, rows, etag, expires}, state) do
    first? = :ets.info(@table, :size) == 0
    persist(rows, etag, expires)
    :ets.delete_all_objects(@table)
    :ets.insert(@table, rows)

    if first?,
      do: Events.emit(:info, "Mercado", "Precios de referencia: #{length(rows)} tipos")

    state = %{state | etag: etag, expires: expires, failures: 0}
    schedule(state, next_delay(state))
  end

  defp handle_result({:not_modified, expires}, state) do
    state = %{state | expires: expires, failures: 0}
    schedule(state, next_delay(state))
  end

  defp handle_result({:error, {kind, until}}, state) when kind in [:paused, :rate_limited] do
    schedule(state, Clock.ms_until(until) + jitter())
  end

  defp handle_result({:error, reason}, state) do
    failures = state.failures + 1
    delay = RegionPoller.backoff_ms(failures)

    Events.emit(
      :warning,
      "Mercado",
      "Precios de referencia: #{inspect(reason)} · reintento en #{div(delay, 1000)} s"
    )

    schedule(%{state | failures: failures}, delay)
  end

  ## Persistencia (RF-1.10)

  defp persist(rows, etag, expires) do
    path = Path.join(Storage.path("market"), @file_name)
    data = :erlang.term_to_binary(%{rows: rows, etag: etag, expires: expires})

    with :ok <- File.write(path <> ".tmp", data), do: File.rename(path <> ".tmp", path)
  end

  defp restore(state) do
    path = Path.join(Storage.path("market"), @file_name)

    with {:ok, binary} <- File.read(path),
         %{rows: rows, etag: etag, expires: expires} <- :erlang.binary_to_term(binary, [:safe]) do
      :ets.insert(@table, rows)
      %{state | etag: etag, expires: expires}
    else
      _ -> state
    end
  end

  ## Utilidades

  # Nunca antes de Expires; sin Expires conocido, ya.
  defp next_delay(%{expires: nil}), do: 0
  defp next_delay(%{expires: expires}), do: Clock.ms_until(expires) + jitter()

  defp jitter, do: Enum.random(GameRules.get(:poll_jitter_ms))

  defp schedule(state, delay_ms) do
    if state.timer, do: Process.cancel_timer(state.timer)
    %{state | timer: Process.send_after(self(), :tick, delay_ms)}
  end
end
