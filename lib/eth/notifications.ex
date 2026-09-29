defmodule Eth.Notifications do
  @moduledoc """
  Notificaciones y reglas de alerta (M10): API pública para la web y otros contextos.

  Cualquier contexto avisa con `notify/1`; `Eth.Notifications.Dispatcher` deduplica con
  enfriamiento por clave (`:notify_cooldown_min`) y publica `{:alert, alerta}` en
  `notifications`. La web lo muestra como toast y, si el navegador lo permite, como
  notificación nativa con sonido opcional (RF-10.2).

  Implementa: RF-10.1, RF-10.2, RF-10.3.
  """

  alias Eth.Accounts
  alias Eth.Notifications.Dispatcher

  @topic "notifications"

  @type alert :: %{
          key: String.t(),
          level: :info | :warning | :error,
          title: String.t(),
          body: String.t(),
          url: String.t() | nil
        }

  @doc "Tópico con las alertas ya filtradas por enfriamiento."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "Pide publicar una alerta (se descarta si la misma clave sonó hace poco)."
  @spec notify(map()) :: :ok
  def notify(alert) do
    alert = Map.merge(%{level: :info, body: "", url: nil}, alert)
    if Process.whereis(Dispatcher), do: GenServer.cast(Dispatcher, {:notify, alert})
    :ok
  end

  @doc "Regla de oportunidades nuevas (RF-10.3): `%{enabled, min_tvs, min_profit}`."
  @spec rule() :: %{enabled: boolean(), min_tvs: non_neg_integer(), min_profit: number()}
  defdelegate rule, to: Accounts, as: :notification_rule

  @doc "Guarda la regla de oportunidades nuevas."
  @spec put_rule(map()) :: :ok | {:error, :invalid_value}
  defdelegate put_rule(attrs), to: Accounts, as: :put_notification_rule
end
