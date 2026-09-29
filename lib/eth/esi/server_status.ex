defmodule Eth.Esi.ServerStatus do
  @moduledoc """
  Estado de Tranquility y detección del downtime diario (RF-1.8).

  Consulta `/status` periódicamente. Se considera downtime si la hora UTC cae en la
  ventana configurada, si ESI marca `vip: true` o si `/status` falla estando dentro de
  una ventana cercana. Los pollers consultan `downtime?/0` antes de descargar, para no
  gastar presupuesto de errores mientras el servidor está caído.

  Implementa: RF-1.8, RNF-2.4.
  """
  use GenServer

  alias Eth.{Clock, Esi, Events, GameRules}

  @table :eth_server_status
  @topic "system:status"

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Tópico PubSub del estado del servidor."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "¿Estamos en downtime? (ventana horaria o `vip`)."
  @spec downtime?() :: boolean()
  def downtime?, do: in_window?(Clock.utc_now()) or vip?()

  @doc "¿La hora dada cae en la ventana de downtime configurada? (función pura)"
  @spec in_window?(DateTime.t()) :: boolean()
  def in_window?(%DateTime{} = now) do
    {from, to} = GameRules.get(:downtime_window_utc)
    time = DateTime.to_time(now)
    Time.compare(time, from) != :lt and Time.compare(time, to) == :lt
  end

  @doc "Fin de la ventana de downtime que contiene (o sigue a) `now`."
  @spec window_end(DateTime.t()) :: DateTime.t()
  def window_end(%DateTime{} = now) do
    {_from, to} = GameRules.get(:downtime_window_utc)
    today_end = DateTime.new!(DateTime.to_date(now), to, "Etc/UTC")

    if DateTime.compare(today_end, now) == :gt,
      do: today_end,
      else: DateTime.add(today_end, 1, :day)
  end

  @doc "Inicio de la próxima ventana de downtime (para la cuenta regresiva)."
  @spec next_downtime(DateTime.t()) :: DateTime.t()
  def next_downtime(%DateTime{} = now) do
    {from, _to} = GameRules.get(:downtime_window_utc)
    today = DateTime.new!(DateTime.to_date(now), from, "Etc/UTC")
    if DateTime.compare(today, now) == :gt, do: today, else: DateTime.add(today, 1, :day)
  end

  @doc "Último estado conocido (`nil` si todavía no se consultó)."
  @spec current() :: map() | nil
  def current do
    if :ets.whereis(@table) != :undefined do
      case :ets.lookup(@table, :status) do
        [{:status, status}] -> status
        [] -> nil
      end
    end
  end

  defp vip?, do: match?(%{vip: true}, current())

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

    # En modo Replay no se consulta ESI (RF-1.11).
    if Eth.Market.data_source() == :replay do
      :ets.insert(@table, {:status, %{online: nil, replay: true, vip: false}})
    else
      send(self(), :poll)
    end

    {:ok, %{online: nil, downtime: false}}
  end

  @impl true
  def handle_info(:poll, state) do
    status = fetch_status()
    :ets.insert(@table, {:status, status})
    Phoenix.PubSub.broadcast(Eth.PubSub, @topic, {:server_status, status})
    Process.send_after(self(), :poll, GameRules.get(:status_poll_ms))
    {:noreply, state |> track_online(status) |> track_downtime()}
  end

  defp fetch_status do
    now = Clock.utc_now()

    case Esi.status() do
      {:ok, %{body: body}} ->
        %{
          online: true,
          players: body["players"],
          server_version: body["server_version"],
          start_time: body["start_time"],
          vip: body["vip"] == true,
          checked_at: now
        }

      {:error, reason} ->
        %{online: false, error: inspect(reason), vip: false, checked_at: now}
    end
  end

  defp track_online(%{online: was} = state, %{online: now_online}) do
    cond do
      was == true and now_online == false ->
        Events.emit(:warning, "Tranquility", "ESI no responde a /status")

      was == false and now_online == true ->
        Events.emit(:info, "Tranquility", "ESI vuelve a responder")

      true ->
        :ok
    end

    %{state | online: now_online}
  end

  defp track_downtime(%{downtime: was} = state) do
    now_downtime = downtime?()

    cond do
      now_downtime and not was ->
        Events.emit(:info, "Tranquility", "Inicio del downtime: pollers en pausa")

      was and not now_downtime ->
        Events.emit(:info, "Tranquility", "Fin del downtime: se reanudan los pollers")

      true ->
        :ok
    end

    %{state | downtime: now_downtime}
  end
end
