defmodule Eth.Metrics do
  @moduledoc """
  Métricas de corto plazo (RF-8.9): buffers circulares de la última hora, por minuto, en
  memoria, para las sparklines del Centro de control.

  - **Contadores** que suman los handlers de telemetría con `:ets.update_counter/4`, en el
    proceso que emite el evento (nunca frenan a ESI ni al motor):
    - `[:eth, :esi, :request]`: requests, errores (HTTP ≥ 400 o de transporte), 304 y la
      latencia;
    - `[:eth, :engine, :evaluate]`: duración de cada evaluación del motor;
    - `[:eth, :engine, :query]`: duración de cada consulta del tablón.
  - **Muestras** que toma este proceso cada minuto: error limit restante y proporción de
    tokens del grupo de mercado (`:market_budget_group`).

  Se guardan `@minutes` minutos y se descartan los más viejos. Nada se persiste: al
  reiniciar, la hora empieza vacía.

  Implementa: RF-8.9.
  """
  use GenServer

  alias Eth.{Clock, GameRules}
  alias Eth.Esi.Budget

  @table :eth_metrics
  @minutes 60
  @handler "eth-metrics"

  @type series :: %{
          minutes: [integer()],
          requests: [non_neg_integer()],
          errors: [non_neg_integer()],
          not_modified: [non_neg_integer()],
          latency_ms: [float() | nil],
          evaluate_ms: [float() | nil],
          query_ms: [float() | nil],
          error_limit: [integer() | nil],
          market_tokens: [float() | nil]
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Series de la última hora, del minuto más viejo al actual (`nil` donde no hubo datos).
  Vacías si el proceso no corre.
  """
  @spec series() :: series()
  def series do
    minutes = minute_range(current_minute())
    rows = if :ets.whereis(@table) == :undefined, do: %{}, else: Map.new(:ets.tab2list(@table))
    get = fn minute, key -> Map.get(rows, {minute, key}) end

    %{
      minutes: minutes,
      requests: Enum.map(minutes, &(get.(&1, :requests) || 0)),
      errors: Enum.map(minutes, &(get.(&1, :errors) || 0)),
      not_modified: Enum.map(minutes, &(get.(&1, :not_modified) || 0)),
      latency_ms: Enum.map(minutes, &average(get.(&1, :latency_sum), get.(&1, :requests))),
      evaluate_ms: Enum.map(minutes, &average(get.(&1, :evaluate_sum), get.(&1, :evaluations))),
      query_ms: Enum.map(minutes, &average(get.(&1, :query_us_sum), get.(&1, :queries), 1_000)),
      error_limit: Enum.map(minutes, &get.(&1, :error_limit)),
      market_tokens: Enum.map(minutes, &get.(&1, :market_tokens))
    }
  end

  @doc """
  Registra una LiveView conectada (RF-8.4): se cuenta mientras su proceso viva; al
  terminar se descuenta sola.
  """
  @spec viewer_joined(pid()) :: :ok
  def viewer_joined(pid) do
    if Process.whereis(__MODULE__), do: GenServer.cast(__MODULE__, {:viewer, pid})
    :ok
  end

  @doc "Pantallas (LiveViews) conectadas ahora."
  @spec viewers() :: non_neg_integer()
  def viewers do
    case :ets.whereis(@table) do
      :undefined ->
        0

      table ->
        table
        |> :ets.lookup(:viewers)
        |> then(fn
          [{_, n}] -> n
          [] -> 0
        end)
    end
  end

  @doc "Minuto actual (minutos Unix)."
  @spec current_minute() :: integer()
  def current_minute, do: div(DateTime.to_unix(Clock.utc_now()), 60)

  defp minute_range(now), do: Enum.to_list((now - @minutes + 1)..now)

  defp average(sum, count, div \\ 1)
  defp average(nil, _count, _div), do: nil
  defp average(_sum, nil, _div), do: nil
  defp average(_sum, 0, _div), do: nil
  defp average(sum, count, div), do: sum / count / div

  ## Handlers de telemetría (corren en el proceso que emite el evento)

  @doc false
  @spec handle_event([atom()], map(), map(), term()) :: :ok
  def handle_event([:eth, :esi, :request], %{duration_ms: ms}, meta, _config) do
    minute = current_minute()
    add(minute, :requests, 1)
    add(minute, :latency_sum, round(ms))
    if error?(meta.status), do: add(minute, :errors, 1)
    if meta[:not_modified], do: add(minute, :not_modified, 1)
    :ok
  end

  def handle_event([:eth, :engine, :evaluate], %{duration_ms: ms}, _meta, _config) do
    minute = current_minute()
    add(minute, :evaluations, 1)
    add(minute, :evaluate_sum, round(ms))
    :ok
  end

  def handle_event([:eth, :engine, :query], %{duration_us: us}, _meta, _config) do
    minute = current_minute()
    add(minute, :queries, 1)
    add(minute, :query_us_sum, us)
    :ok
  end

  defp error?(:transport_error), do: true
  defp error?(status) when is_integer(status), do: status >= 400
  defp error?(_status), do: false

  # Sin tabla (proceso caído o apagado) no se cuenta: la telemetría nunca falla.
  defp add(minute, key, n) do
    :ets.update_counter(@table, {minute, key}, n, {{minute, key}, 0})
  rescue
    ArgumentError -> :ok
  end

  ## Proceso: dueño de la tabla, muestras por minuto y limpieza

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])

    :telemetry.attach_many(
      @handler,
      [[:eth, :esi, :request], [:eth, :engine, :evaluate], [:eth, :engine, :query]],
      &__MODULE__.handle_event/4,
      nil
    )

    send(self(), :sample)
    {:ok, nil}
  end

  @impl true
  def handle_cast({:viewer, pid}, state) do
    Process.monitor(pid)
    :ets.update_counter(@table, :viewers, 1, {:viewers, 0})
    {:noreply, state}
  end

  @impl true
  def handle_info(:sample, state) do
    minute = current_minute()
    sample(minute)
    prune(minute)
    Process.send_after(self(), :sample, 60_000)
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    :ets.update_counter(@table, :viewers, -1, {:viewers, 0})
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, _state), do: :telemetry.detach(@handler)

  defp sample(minute) do
    budget = Budget.snapshot()

    if el = budget.error_limit,
      do: :ets.insert(@table, {{minute, :error_limit}, el.remain})

    group = GameRules.get(:market_budget_group)
    :ets.insert(@table, {{minute, :market_tokens}, Budget.remaining_ratio(group)})
  rescue
    # Sin presupuesto todavía (arranque o tests): se omite la muestra.
    ArgumentError -> :ok
  end

  defp prune(minute) do
    oldest = minute - @minutes + 1
    :ets.select_delete(@table, [{{{:"$1", :_}, :_}, [{:<, :"$1", oldest}], [true]}])
  end
end
