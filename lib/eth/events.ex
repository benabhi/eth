defmodule Eth.Events do
  @moduledoc """
  Registro de eventos del sistema (RF-8.7): errores, backoffs, pausas, downtime, acciones
  manuales y alertas. Cada evento se persiste (retención de 7 días) y se publica en el
  tópico `system:events` para el Centro de control.

  Los mensajes se escriben en español (RNF-6.2).

  Implementa: RF-8.7, RNF-9.1.
  """

  import Ecto.Query

  require Logger

  alias Eth.Clock
  alias Eth.Events.Event
  alias Eth.Repo

  @topic "system:events"
  @retention_days 7

  @type level :: :info | :warning | :error | :action

  @doc "Tópico PubSub de eventos."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc """
  Registra un evento. Nunca falla: si la base no está disponible, el evento se publica
  igual y queda en el log de la aplicación.
  """
  @spec emit(level(), String.t(), String.t(), map()) :: Event.t()
  def emit(level, source, message, metadata \\ %{})
      when level in [:info, :warning, :error, :action] do
    event = %Event{
      at: Clock.utc_now(),
      level: Atom.to_string(level),
      source: source,
      message: message,
      metadata: metadata
    }

    event = persist(event)
    log(level, "[#{source}] #{message}")
    Phoenix.PubSub.broadcast(Eth.PubSub, @topic, {:system_event, event})
    event
  end

  @doc "Eventos más recientes primero. Filtros: `:level`, `:source`, `:search`."
  @spec recent(pos_integer(), keyword()) :: [Event.t()]
  def recent(limit \\ 100, filters \\ []) do
    Event
    |> order_by(desc: :at, desc: :id)
    |> limit(^limit)
    |> filter(filters)
    |> Repo.all()
  end

  @doc "Borra los eventos más viejos que la retención (7 días)."
  @spec prune() :: non_neg_integer()
  def prune do
    cutoff = DateTime.add(Clock.utc_now(), -@retention_days, :day)
    {count, _} = Repo.delete_all(from e in Event, where: e.at < ^cutoff)
    count
  end

  defp filter(query, filters) do
    Enum.reduce(filters, query, fn
      {:level, level}, q when is_binary(level) ->
        where(q, level: ^level)

      {:source, source}, q when is_binary(source) ->
        where(q, source: ^source)

      {:search, text}, q when is_binary(text) and text != "" ->
        where(q, [e], ilike(e.message, ^"%#{text}%"))

      _, q ->
        q
    end)
  end

  defp persist(event) do
    Repo.insert!(event)
  rescue
    error ->
      Logger.warning("No se pudo persistir el evento del sistema: #{Exception.message(error)}")
      event
  end

  defp log(:error, message), do: Logger.error(message)
  defp log(:warning, message), do: Logger.warning(message)
  defp log(_level, message), do: Logger.info(message)
end
