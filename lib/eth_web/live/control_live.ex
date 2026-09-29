defmodule EthWeb.ControlLive do
  @moduledoc """
  Centro de control: tablero operativo del sistema (ERS §9.6).

  - Barra de salud global: Tranquility, error limit, presupuesto de mercado, pausa global,
    memoria y próximo downtime.
  - Mapa de regiones en mosaico agrupado por nivel, con estado, cuenta regresiva y
    progreso; clic para ver el detalle y actuar.
  - Sesiones de personajes: token, modo de polling y última lectura de cada dato (RF-8.6).
  - Registro de eventos en vivo, filtrable.

  Se actualiza por PubSub; un tick por segundo refresca las cuentas regresivas.

  Implementa: RF-8.1, RF-8.2, RF-8.3, RF-8.6, RF-8.7, RF-8.8, RF-8.9.
  """
  use EthWeb, :live_view

  alias Eth.Characters.Sessions
  alias Eth.{Clock, Events, Market, Sde}
  alias Eth.Esi.{Budget, ServerStatus}
  alias EthWeb.Format

  @event_limit 60
  @tiers [hub: "N1 · Hubs", active: "N2 · Activas", rest: "N3 · Resto"]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Eth.PubSub, Market.status_topic())
      Phoenix.PubSub.subscribe(Eth.PubSub, Events.topic())
      Phoenix.PubSub.subscribe(Eth.PubSub, ServerStatus.topic())
      Phoenix.PubSub.subscribe(Eth.PubSub, Sde.topic())
      schedule_tick()
    end

    socket =
      socket
      |> assign(:page_title, gettext("Centro de control"))
      |> assign(:regions, Map.new(Market.region_statuses(), &{&1.region_id, &1}))
      |> assign(:selected, nil)
      |> assign(:event_level, nil)
      |> assign(:events, Events.recent(@event_limit))
      |> assign(:tiers, @tiers)
      |> assign(:dev_routes, Application.get_env(:eth, :dev_routes, false))
      |> assign(:sde, Sde.status())
      |> assign(:sessions, Sessions.list())
      |> refresh_health()

    {:ok, socket}
  end

  ## Mensajes

  @impl true
  def handle_info({:region_status, status}, socket) do
    {:noreply, update(socket, :regions, &Map.put(&1, status.region_id, status))}
  end

  def handle_info({:system_event, event}, socket) do
    if socket.assigns.event_level in [nil, event.level] do
      {:noreply, update(socket, :events, &Enum.take([event | &1], @event_limit))}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:server_status, _status}, socket), do: {:noreply, refresh_health(socket)}
  def handle_info({:sde_status, status}, socket), do: {:noreply, assign(socket, :sde, status)}
  def handle_info({:esi_paused, _until, _reason}, socket), do: {:noreply, refresh_health(socket)}
  def handle_info(:esi_resumed, socket), do: {:noreply, refresh_health(socket)}

  # El piloto lo actualiza `EthWeb.PilotHook`; las sesiones se refrescan con el tick.
  def handle_info({:character, _id, _event, _public}, socket), do: {:noreply, socket}

  def handle_info(:tick, socket) do
    schedule_tick()
    {:noreply, socket |> assign(:sessions, Sessions.list()) |> refresh_health()}
  end

  ## Eventos de la UI

  @impl true
  def handle_event("select_region", %{"id" => id}, socket) do
    {:noreply, assign(socket, :selected, String.to_integer(id))}
  end

  def handle_event("close_detail", _params, socket),
    do: {:noreply, assign(socket, :selected, nil)}

  def handle_event("refresh_now", %{"id" => id}, socket) do
    case Market.refresh_now(String.to_integer(id)) do
      :ok ->
        {:noreply, put_flash(socket, :info, gettext("Actualización solicitada"))}

      {:error, :not_expired} ->
        {:noreply,
         put_flash(socket, :error, gettext("ESI todavía no tiene datos nuevos para esta región"))}

      {:error, :busy} ->
        {:noreply, put_flash(socket, :error, gettext("La región ya se está descargando"))}

      {:error, :paused} ->
        {:noreply,
         put_flash(socket, :error, gettext("La región está en pausa: reanudala primero"))}
    end
  end

  def handle_event("pause_region", %{"id" => id}, socket) do
    :ok = Market.pause(String.to_integer(id))
    {:noreply, socket}
  end

  def handle_event("resume_region", %{"id" => id}, socket) do
    :ok = Market.resume(String.to_integer(id))
    {:noreply, socket}
  end

  def handle_event("pause_esi", _params, socket) do
    Budget.pause_all(DateTime.add(Clock.utc_now(), 365, :day), :manual)
    Events.emit(:action, "Usuario", "Pausa global de ESI")
    {:noreply, refresh_health(socket)}
  end

  def handle_event("resume_esi", _params, socket) do
    Budget.resume_all()
    Events.emit(:action, "Usuario", "Reanudación global de ESI")
    {:noreply, refresh_health(socket)}
  end

  def handle_event("filter_events", %{"level" => level}, socket) do
    level = if level == "", do: nil, else: level
    filters = if level, do: [level: level], else: []

    {:noreply,
     socket
     |> assign(:event_level, level)
     |> assign(:events, Events.recent(@event_limit, filters))}
  end

  ## Datos derivados

  defp schedule_tick, do: Process.send_after(self(), :tick, 1_000)

  defp refresh_health(socket) do
    now = Clock.utc_now()

    assign(socket,
      now: now,
      server: ServerStatus.current(),
      budget: Budget.snapshot(),
      market_budget: Budget.group(Eth.GameRules.get(:market_budget_group)),
      memory: %{total: :erlang.memory(:total), ets: :erlang.memory(:ets)},
      next_downtime: ServerStatus.next_downtime(now)
    )
  end

  @doc false
  # Estado visual de un mosaico: {clave, etiqueta, clase de color}. Prioriza lo que el
  # poller está haciendo; si está en reposo, muestra la frescura de sus datos.
  @spec display(map(), DateTime.t()) :: {atom(), String.t(), String.t()}
  def display(%{status: :fetching}, _now), do: {:fetching, gettext("Descargando"), "info"}
  def display(%{status: :backoff}, _now), do: {:backoff, gettext("Error"), "error"}

  def display(%{status: :rate_limited}, _now),
    do: {:rate_limited, gettext("Limitado"), "secondary"}

  def display(%{status: :paused, pause_reason: :downtime}, _now),
    do: {:paused, gettext("Downtime"), "neutral"}

  def display(%{status: :paused}, _now), do: {:paused, gettext("Pausado"), "neutral"}

  def display(status, now) do
    case Market.freshness(status.last_modified, status.expires, now) do
      :none -> {:none, gettext("Sin datos"), "neutral"}
      :fresh -> fresh_label(status)
      :degraded -> {:degraded, gettext("Degradado"), "warning"}
      :stale -> {:stale, gettext("Viejo"), "warning"}
      :excluded -> {:excluded, gettext("Excluido"), "error"}
    end
  end

  defp fresh_label(%{replay: true}), do: {:fresh, gettext("Replay"), "success"}
  defp fresh_label(%{restored: true}), do: {:fresh, gettext("Restaurado"), "success"}
  defp fresh_label(_status), do: {:fresh, gettext("Cacheado"), "success"}

  # Texto secundario del mosaico según el estado.
  defp timing(%{status: :fetching, progress: {done, total}}, _now) when is_integer(total),
    do: gettext("Pág %{done}/%{total}", done: done, total: total)

  defp timing(%{status: :fetching}, _now), do: gettext("Iniciando…")
  defp timing(%{status: :backoff, next_at: at}, now), do: "reint. " <> Format.countdown(at, now)

  defp timing(%{status: :rate_limited, next_at: at}, now),
    do: "espera " <> Format.countdown(at, now)

  defp timing(%{status: :paused, pause_reason: :manual}, _now), do: gettext("manual")
  defp timing(%{next_at: at}, now), do: "T-" <> Format.countdown(at, now)

  # Mosaicos de un nivel ya con su estado visual calculado.
  defp tiles(regions, tier, now) do
    for status <- regions_in_tier(regions, tier), do: {status, display(status, now)}
  end

  # Clases literales (Tailwind solo incluye clases que aparecen completas en el código).
  defp tone_border("success"), do: "border-l-success"
  defp tone_border("info"), do: "border-l-info"
  defp tone_border("error"), do: "border-l-error"
  defp tone_border("warning"), do: "border-l-warning"
  defp tone_border("secondary"), do: "border-l-secondary"
  defp tone_border(_neutral), do: "border-l-base-content/30"

  defp tone_text("success"), do: "text-success"
  defp tone_text("info"), do: "text-info"
  defp tone_text("error"), do: "text-error"
  defp tone_text("warning"), do: "text-warning"
  defp tone_text("secondary"), do: "text-secondary"
  defp tone_text(_neutral), do: "text-base-content/70"

  defp status_icon(:fetching), do: "◐"
  defp status_icon(key) when key in [:backoff, :excluded], do: "×"
  defp status_icon(key) when key in [:degraded, :stale], do: "▲"
  defp status_icon(:rate_limited), do: "◆"
  defp status_icon(key) when key in [:paused, :none], do: "□"
  defp status_icon(_fresh), do: "●"

  defp tier_label(:hub), do: gettext("N1 · Hub")
  defp tier_label(:active), do: gettext("N2 · Activa")
  defp tier_label(_rest), do: gettext("N3 · Resto")

  defp progress_pct(%{progress: {done, total}}) when is_integer(total) and total > 0,
    do: round(done * 100 / total)

  defp progress_pct(_status), do: 0

  defp regions_in_tier(regions, tier) do
    regions
    |> Map.values()
    |> Enum.filter(&(&1.tier == tier))
    |> Enum.sort_by(& &1.name)
  end

  defp totals(regions) do
    values = Map.values(regions)

    %{
      count: length(values),
      fresh:
        Enum.count(
          values,
          &(&1.status != :fetching and display(&1, Clock.utc_now()) |> elem(0) == :fresh)
        ),
      orders: values |> Enum.map(&(&1.orders || 0)) |> Enum.sum(),
      bytes: values |> Enum.map(&(&1.bytes || 0)) |> Enum.sum()
    }
  end

  defp budget_used_pct(%{limit: limit, remaining: remaining}) when limit > 0,
    do: round((limit - remaining) * 100 / limit)

  defp budget_used_pct(_budget), do: 0

  defp sde_label(%{state: :ready}), do: {gettext("Listo"), "text-success", "●"}
  defp sde_label(%{state: :downloading}), do: {gettext("Descargando"), "text-info", "◐"}
  defp sde_label(%{state: :processing}), do: {gettext("Procesando"), "text-info", "◐"}
  defp sde_label(%{state: :error}), do: {gettext("Error"), "text-error", "×"}
  defp sde_label(%{state: :stopped}), do: {gettext("Detenido"), "text-base-content/70", "□"}
  defp sde_label(_loading), do: {gettext("Cargando"), "text-base-content/70", "◐"}

  defp level_badge("error"), do: {"ERROR", "badge-error"}
  defp level_badge("warning"), do: {"AVISO", "badge-warning"}
  defp level_badge("action"), do: {"ACCIÓN", "badge-secondary"}
  defp level_badge(_level), do: {"INFO", "badge-ghost"}

  # Sparkline SVG de duraciones de los últimos ciclos (más viejo a la izquierda).
  defp sparkline_points(history) do
    values = history |> Enum.reverse() |> Enum.map(& &1.duration_ms)

    case values do
      [] ->
        ""

      [_single] ->
        "0,10 100,10"

      _ ->
        max = Enum.max(values)
        step = 100 / (length(values) - 1)

        values
        |> Enum.with_index()
        |> Enum.map_join(" ", fn {v, i} ->
          "#{Float.round(i * step, 1)},#{Float.round(20 - v / max(max, 1) * 18, 1)}"
        end)
    end
  end

  ## Sesiones de personajes (RF-8.6)

  defp session_resources, do: [:online, :location, :ship, :wallet, :skills, :standings, :assets]

  defp resource_label(:online), do: gettext("En línea")
  defp resource_label(:location), do: gettext("Ubicación")
  defp resource_label(:ship), do: gettext("Nave")
  defp resource_label(:wallet), do: gettext("Billetera")
  defp resource_label(:skills), do: gettext("Habilidades")
  defp resource_label(:standings), do: gettext("Standings")
  defp resource_label(:assets), do: gettext("Módulos montados")

  defp session_label(:ok), do: gettext("token vigente")
  defp session_label(:relogin), do: gettext("re-login requerido")
  defp session_label(:token_error), do: gettext("error de token")
  defp session_label(_status), do: gettext("conectando")

  defp session_class(:ok), do: "badge-success"
  defp session_class(:relogin), do: "badge-warning"
  defp session_class(:token_error), do: "badge-error"
  defp session_class(_status), do: "badge-ghost"

  defp mode_label(:active), do: gettext("polling activo (UI abierta)")
  defp mode_label(:idle), do: gettext("en línea, sin UI")
  defp mode_label(:offline), do: gettext("offline, polling reducido")
  defp mode_label(_mode), do: ""
end
