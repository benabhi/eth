defmodule Eth.Notifications.Dispatcher do
  @moduledoc """
  Despachador de alertas (RF-10.1, RF-10.3).

  - Recibe alertas con `Eth.Notifications.notify/1` y las publica en `notifications`, salvo
    que la misma clave haya sonado hace menos de `:notify_cooldown_min` (anti-spam).
  - **Oportunidades nuevas:** con cada evaluación del motor busca contratos que cumplan la
    regla del operador (TVS y beneficio mínimos, con los parámetros del modo invitado) y
    que no estaban en la evaluación anterior. La primera evaluación solo siembra el
    conjunto, para no avisar todo el tablón al arrancar.
  - **Tokens:** avisa cuando la sesión de un personaje pide volver a loguear.

  La consulta al motor corre en una tarea supervisada.

  Implementa: RF-10.1, RF-10.3.
  """
  use GenServer

  alias Eth.{Characters, Clock, Engine, GameRules, Notifications}
  alias Eth.Characters.Session

  @max_per_evaluation 3

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(Eth.PubSub, Engine.topic())
    for c <- Characters.list(), do: Phoenix.PubSub.subscribe(Eth.PubSub, Session.topic(c.id))
    {:ok, %{sent: %{}, seen: nil, task: nil}}
  end

  @impl true
  def handle_cast({:notify, alert}, state), do: {:noreply, publish(state, alert)}

  @impl true
  def handle_info({:opportunities_updated, _meta}, %{task: nil} = state) do
    rule = Notifications.rule()
    task = Task.Supervisor.async_nolink(Eth.Engine.TaskSupervisor, fn -> candidates(rule) end)
    {:noreply, %{state | task: task}}
  end

  def handle_info({:opportunities_updated, _meta}, state), do: {:noreply, state}

  def handle_info({ref, {rule, rows}}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    ids = MapSet.new(rows, & &1.id)

    state =
      case state.seen do
        nil ->
          state

        seen ->
          rows
          |> Enum.reject(&MapSet.member?(seen, &1.id))
          |> Enum.take(if rule.enabled, do: @max_per_evaluation, else: 0)
          |> Enum.reduce(state, &publish(&2, opportunity_alert(&1)))
      end

    {:noreply, %{state | seen: ids, task: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{task: %Task{ref: ref}} = state),
    do: {:noreply, %{state | task: nil}}

  def handle_info({:character, id, :relogin, public}, state) do
    alert = %{
      key: "relogin:#{id}",
      level: :error,
      title: "#{public[:name] || "Personaje"}: la autorización de EVE venció",
      body: "Volvé a iniciar sesión con EVE para seguir usando sus datos",
      url: "/settings"
    }

    {:noreply, publish(state, alert)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Corre en la tarea: contratos que cumplen la regla (vacío si está apagada).
  defp candidates(rule) do
    if rule.enabled do
      {rows, _total} = Engine.query(%{min_profit: rule.min_profit, limit: 200})
      {rule, Enum.filter(rows, &(&1.tvs >= rule.min_tvs and &1.shield.status != :scam))}
    else
      {rule, []}
    end
  end

  defp opportunity_alert(row) do
    opp = row.opportunity

    %{
      key: "opp:#{row.id}",
      level: :info,
      title: "Nuevo contrato: #{opp.type_name} · +#{round(row.profit / 1.0e6)}M · TVS #{row.tvs}",
      body: "#{opp.origin.name} → #{opp.destination.name}",
      url: "/?search=#{URI.encode_www_form(opp.type_name)}"
    }
  end

  # Anti-spam: la misma clave no vuelve a sonar antes del enfriamiento.
  defp publish(state, alert) do
    now = Clock.utc_now()
    cooldown_s = GameRules.get(:notify_cooldown_min) * 60
    # Se olvidan las claves que ya salieron del enfriamiento (el mapa no crece sin límite).
    sent = Map.filter(state.sent, fn {_key, at} -> DateTime.diff(now, at) < cooldown_s end)

    if Map.has_key?(sent, alert.key) do
      %{state | sent: sent}
    else
      Phoenix.PubSub.broadcast(Eth.PubSub, Notifications.topic(), {:alert, alert})
      %{state | sent: Map.put(sent, alert.key, now)}
    end
  end
end
