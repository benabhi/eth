defmodule Eth.Characters.Session do
  @moduledoc """
  Sesión de un personaje (RF-5.3, RF-5.4): tokens y polling de su contexto en ESI.

  **Tokens.** El access token (20 min) vive solo en memoria y se renueva 60 s antes de
  vencer; el refresh token rotado se persiste cifrado. `invalid_grant` ⇒ estado
  `:relogin`, se detiene el polling y la UI pide volver a loguear.

  **Polling según actividad** (tabla RF-5.4), siempre ≥ `Expires` y con ETag:

  | Recurso | Activo (en línea + UI) | En línea sin UI | Offline |
  |---|---|---|---|
  | ubicación, nave | 10 s | 60 s | en pausa |
  | en línea | 60 s | 60 s | 5 min |
  | billetera | 2 min | 10 min | 30 min |
  | habilidades | 30 min | 60 min | 6 h |
  | standings | 60 min | 6 h | 24 h |
  | assets (módulos montados) | 60 min | 60 min | 6 h |
  | órdenes propias | 5 min | 20 min | 60 min |

  De los assets solo se guardan los módulos montados en cada nave
  (`%{ship_item_id => [type_id]}`), para calcular la bodega (RF-5.8).

  "UI activa" = algún LiveView observa al personaje (`watch/1`). Cada cambio del
  contexto se publica en `character:<id>`.

  Para el Centro de control (RF-8.6) publica también el vencimiento del token y, por
  recurso, la última lectura y el próximo pedido.

  Implementa: RF-5.3, RF-5.4, RF-5.5, RF-5.6, RF-5.7, RF-5.8, RF-8.6.
  """
  use GenServer

  alias Eth.{Characters, Clock, Esi, Events, GameRules, Sso}
  alias Eth.Esi.Response
  alias Eth.Sso.Token

  @resources [:online, :location, :ship, :wallet, :skills, :standings, :assets, :orders]
  @scopes %{
    online: "esi-location.read_online.v1",
    location: "esi-location.read_location.v1",
    ship: "esi-location.read_ship_type.v1",
    wallet: "esi-wallet.read_character_wallet.v1",
    skills: "esi-skills.read_skills.v1",
    standings: "esi-characters.read_standings.v1",
    assets: "esi-assets.read_assets.v1",
    orders: "esi-markets.read_character_orders.v1"
  }
  @intervals %{
    location: %{active: 10_000, idle: 60_000, offline: nil},
    ship: %{active: 10_000, idle: 60_000, offline: nil},
    online: %{active: 60_000, idle: 60_000, offline: 300_000},
    wallet: %{active: 120_000, idle: 600_000, offline: 1_800_000},
    skills: %{active: 1_800_000, idle: 3_600_000, offline: 21_600_000},
    standings: %{active: 3_600_000, idle: 21_600_000, offline: 86_400_000},
    assets: %{active: 3_600_000, idle: 3_600_000, offline: 21_600_000},
    orders: %{active: 300_000, idle: 1_200_000, offline: 3_600_000}
  }
  @error_retry_ms 60_000
  @refresh_margin_s 60

  ## API

  @spec start_link({pos_integer(), Sso.login() | nil}) :: GenServer.on_start()
  def start_link({id, login}), do: GenServer.start_link(__MODULE__, {id, login}, name: via(id))

  @spec child_spec({pos_integer(), Sso.login() | nil}) :: Supervisor.child_spec()
  def child_spec({id, _login} = arg) do
    %{id: {__MODULE__, id}, start: {__MODULE__, :start_link, [arg]}, restart: :transient}
  end

  @doc false
  @spec via(pos_integer()) :: GenServer.name()
  def via(id), do: {:via, Registry, {Eth.Characters.Registry, id}}

  @doc "Tópico PubSub del personaje."
  @spec topic(pos_integer()) :: String.t()
  def topic(id), do: "character:#{id}"

  ## Callbacks

  @impl true
  def init({id, login}) do
    character = Characters.get(id)

    state =
      Map.merge(
        %{
          id: id,
          status: :starting,
          viewers: %{},
          context: %{},
          etags: %{},
          timers: %{},
          read_at: %{},
          next_at: %{}
        },
        initial_credentials(character, login)
      )

    {:ok, state, {:continue, :token}}
  end

  # Credenciales iniciales: las del login recién hecho o, si no hay, las persistidas.
  defp initial_credentials(character, nil) do
    %{
      name: character && character.name,
      scopes: (character && character.scopes) || [],
      access_token: nil,
      expires_at: nil,
      refresh_token: character && character.refresh_token
    }
  end

  defp initial_credentials(_character, login) do
    %{
      name: login.name,
      scopes: login.scopes,
      access_token: login.access_token,
      expires_at: login.expires_at,
      refresh_token: login.refresh_token
    }
  end

  @impl true
  def handle_continue(:token, state) do
    state =
      if state.access_token && DateTime.compare(state.expires_at, Clock.utc_now()) == :gt,
        do: token_ready(state),
        else: refresh(state)

    {:noreply, state}
  end

  @impl true
  def handle_call(:context, _from, state), do: {:reply, public(state), state}

  def handle_call({:watch, pid}, _from, state) do
    state =
      if Map.has_key?(state.viewers, pid),
        do: state,
        else: %{state | viewers: Map.put(state.viewers, pid, Process.monitor(pid))}

    # Pasar a modo activo: la ubicación y la nave se piden ya.
    {:reply, public(state), reschedule(state, [:location, :ship], 0)}
  end

  def handle_call(:token, _from, %{status: :ok} = state) do
    {:reply, {:ok, state.access_token}, state}
  end

  def handle_call(:token, _from, state), do: {:reply, {:error, state.status}, state}

  def handle_call({:login, login}, _from, state) do
    state = %{
      state
      | access_token: login.access_token,
        expires_at: login.expires_at,
        refresh_token: login.refresh_token,
        scopes: login.scopes
    }

    {:reply, :ok, token_ready(state)}
  end

  @impl true
  def handle_info(:refresh_token, state), do: {:noreply, refresh(state)}

  def handle_info({:poll, resource}, %{status: :ok} = state) do
    {:noreply, poll(state, resource)}
  end

  def handle_info({:poll, _resource}, state), do: {:noreply, state}

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | viewers: Map.delete(state.viewers, pid)}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  ## Tokens

  defp refresh(%{refresh_token: nil} = state), do: relogin(state, "sin refresh token")

  defp refresh(state) do
    case Token.refresh(state.refresh_token) do
      {:ok, tokens} ->
        if tokens.refresh_token && tokens.refresh_token != state.refresh_token do
          Characters.update_refresh_token(state.id, tokens.refresh_token)
        end

        state
        |> Map.merge(%{
          access_token: tokens.access_token,
          expires_at: tokens.expires_at,
          refresh_token: tokens.refresh_token || state.refresh_token
        })
        |> token_ready()

      {:error, :invalid_grant} ->
        relogin(state, "el SSO rechazó el refresh token")

      {:error, reason} ->
        Process.send_after(self(), :refresh_token, @error_retry_ms)
        broadcast(%{state | status: :token_error}, {:token_error, reason})
    end
  end

  defp token_ready(state) do
    delay = max(Clock.ms_until(state.expires_at) - @refresh_margin_s * 1000, 1_000)
    Process.send_after(self(), :refresh_token, delay)
    was_ok = state.status == :ok
    state = %{state | status: :ok}
    state = if was_ok, do: state, else: reschedule(state, @resources, 0)
    broadcast(state, :token_ok)
  end

  defp relogin(state, reason) do
    Characters.mark_relogin(state.id)

    Events.emit(
      :warning,
      "Personajes",
      "#{state.name || state.id} debe volver a loguear: #{reason}"
    )

    state = cancel_all(state)
    broadcast(%{state | status: :relogin, access_token: nil}, :relogin)
  end

  ## Polling

  defp poll(state, resource) do
    if Map.fetch!(@scopes, resource) in state.scopes do
      state
      |> fetch(resource)
      |> handle_response(state, resource)
    else
      # Sin el scope no se consulta: el recurso queda sin próxima consulta.
      cancel(state, resource)
    end
  end

  defp fetch(state, :assets), do: fetch_assets(state)

  defp fetch(state, resource) do
    fun =
      case resource do
        :location -> &Esi.character_location/3
        :ship -> &Esi.character_ship/3
        :online -> &Esi.character_online/3
        :wallet -> &Esi.character_wallet/3
        :skills -> &Esi.character_skills/3
        :standings -> &Esi.character_standings/3
        :orders -> &Esi.character_orders/3
      end

    fun.(state.id, state.access_token, Map.get(state.etags, resource))
  end

  # Assets paginados: la página 1 con ETag; si cambió, se piden las demás y se unen.
  defp fetch_assets(state) do
    etag = Map.get(state.etags, :assets)

    case Esi.character_assets(state.id, state.access_token, 1, etag) do
      {:ok, %Response{status: 200, pages: pages} = first} when is_integer(pages) and pages > 1 ->
        fetch_asset_pages(state, first, 2..pages//1)

      other ->
        other
    end
  end

  defp fetch_asset_pages(state, first, pages) do
    Enum.reduce_while(pages, {:ok, first}, fn page, {:ok, acc} ->
      case Esi.character_assets(state.id, state.access_token, page) do
        {:ok, %Response{status: 200, body: items}} ->
          {:cont, {:ok, %{acc | body: acc.body ++ items}}}

        {:ok, resp} ->
          {:halt, {:error, {:http, resp}}}

        error ->
          {:halt, error}
      end
    end)
  end

  defp handle_response({:ok, %Response{status: 304} = resp}, state, resource) do
    state |> mark_read(resource) |> schedule(resource, resp)
  end

  defp handle_response({:ok, %Response{} = resp}, state, resource) do
    before = state.context
    context = Map.put(state.context, resource, parse(resource, resp.body))

    state =
      %{state | context: context, etags: Map.put(state.etags, resource, resp.etag)}
      |> mark_read(resource)
      |> schedule(resource, resp)

    # Cambiar de en línea a offline (o al revés) reprograma todo con el modo nuevo.
    state =
      if resource == :online and before[:online] != context[:online],
        do: reschedule(state, @resources -- [:online], 0),
        else: state

    if before[resource] != context[resource],
      do: broadcast(state, {:updated, resource}),
      else: state
  end

  defp handle_response({:error, {:http, %Response{status: 403}}}, state, resource) do
    # Scope no concedido o revocado para este recurso: no se insiste.
    cancel(%{state | scopes: List.delete(state.scopes, Map.fetch!(@scopes, resource))}, resource)
  end

  defp handle_response({:error, {kind, until}}, state, resource)
       when kind in [:paused, :rate_limited] do
    reschedule(state, [resource], Clock.ms_until(until) + 1_000)
  end

  defp handle_response({:error, _reason}, state, resource) do
    reschedule(state, [resource], @error_retry_ms)
  end

  defp parse(:location, body) do
    %{
      solar_system_id: body["solar_system_id"],
      station_id: body["station_id"],
      structure_id: body["structure_id"]
    }
  end

  defp parse(:ship, body) do
    %{
      ship_type_id: body["ship_type_id"],
      ship_item_id: body["ship_item_id"],
      ship_name: body["ship_name"]
    }
  end

  defp parse(:online, body), do: body["online"] == true
  defp parse(:wallet, body), do: body / 1

  defp parse(:skills, body) do
    for %{"skill_id" => id} = skill <- body["skills"] || [], into: %{} do
      {id, skill["active_skill_level"] || 0}
    end
  end

  defp parse(:assets, items) do
    prefixes = GameRules.get(:fitted_location_flag_prefixes)

    items
    |> Enum.filter(&(&1["location_type"] == "item" and fitted?(&1["location_flag"], prefixes)))
    |> Enum.group_by(& &1["location_id"], & &1["type_id"])
  end

  # Órdenes personales abiertas (las de corporación no se usan, §1.5).
  defp parse(:orders, body) do
    for %{"order_id" => id} = o <- body, o["is_corporation"] != true do
      %{
        order_id: id,
        type_id: o["type_id"],
        region_id: o["region_id"],
        location_id: o["location_id"],
        buy: o["is_buy_order"] == true,
        price: o["price"] / 1,
        volume_remain: o["volume_remain"],
        volume_total: o["volume_total"],
        min_volume: o["min_volume"] || 1,
        range: o["range"],
        escrow: (o["escrow"] || 0) / 1,
        duration: o["duration"],
        issued: parse_datetime(o["issued"])
      }
    end
  end

  defp parse(:standings, body) do
    for %{"from_id" => id, "standing" => standing} <- body, into: %{}, do: {id, standing}
  end

  defp parse_datetime(nil), do: nil

  defp parse_datetime(text) do
    case DateTime.from_iso8601(text) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp fitted?(flag, prefixes) when is_binary(flag),
    do: Enum.any?(prefixes, &String.starts_with?(flag, &1))

  defp fitted?(_flag, _prefixes), do: false

  # Próximo pedido: el intervalo del modo actual, pero nunca antes de Expires.
  defp schedule(state, resource, %Response{expires: expires}) do
    case interval(state, resource) do
      nil -> cancel(state, resource)
      ms -> reschedule(state, [resource], max(ms, (expires && Clock.ms_until(expires)) || 0))
    end
  end

  defp interval(state, resource), do: get_in(@intervals, [resource, mode(state)])

  defp mode(state) do
    cond do
      state.context[:online] == false -> :offline
      map_size(state.viewers) > 0 -> :active
      true -> :idle
    end
  end

  defp reschedule(state, resources, delay) do
    Enum.reduce(resources, state, fn resource, acc ->
      acc = cancel(acc, resource)

      if mode(acc) == :offline and interval(acc, resource) == nil and resource != :online do
        acc
      else
        ref = Process.send_after(self(), {:poll, resource}, delay)
        next = DateTime.add(Clock.utc_now(), delay, :millisecond)

        %{
          acc
          | timers: Map.put(acc.timers, resource, ref),
            next_at: Map.put(acc.next_at, resource, next)
        }
      end
    end)
  end

  defp cancel(state, resource) do
    if ref = state.timers[resource], do: Process.cancel_timer(ref)

    %{
      state
      | timers: Map.delete(state.timers, resource),
        next_at: Map.delete(state.next_at, resource)
    }
  end

  # Última lectura exitosa (200 o 304) de cada recurso, para el Centro de control (RF-8.6).
  defp mark_read(state, resource),
    do: %{state | read_at: Map.put(state.read_at, resource, Clock.utc_now())}

  defp cancel_all(state), do: Enum.reduce(@resources, state, &cancel(&2, &1))

  defp public(state) do
    %{
      id: state.id,
      name: state.name,
      status: state.status,
      scopes: state.scopes,
      context: state.context,
      mode: mode(state),
      token_expires_at: state.expires_at,
      read_at: state.read_at,
      next_at: state.next_at
    }
  end

  defp broadcast(state, event) do
    Phoenix.PubSub.broadcast(
      Eth.PubSub,
      topic(state.id),
      {:character, state.id, event, public(state)}
    )

    state
  end
end
