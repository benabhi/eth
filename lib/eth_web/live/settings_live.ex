defmodule EthWeb.SettingsLive do
  @moduledoc """
  Ajustes (ERS §9.2): pestañas por `live_action`.

  - **Personajes** (RF-9.2): activar, volver a loguear y olvidar; scopes concedidos frente
    a requeridos y estado de la sesión y del token.
  - **Naves** (RF-9.3): editar y borrar los perfiles de carga guardados.
  - **Reglas** (RF-9.4): overrides de impuestos y coeficientes del broker, con el valor por
    defecto y su fecha de verificación.
  - **Radar** (RF-9.5): α del modo Evasiva y sistemas a evitar.
  - **Regiones y estructuras** (RF-9.6): regiones habilitadas y su nivel; estructuras
    seguidas, acceso por personaje, agregar por ID y broker fee por estructura (RF-9.4).
  - **Primer arranque** (RF-9.1): checklist de puesta en marcha.

  Implementa: RF-9.1, RF-9.2, RF-9.3, RF-9.4, RF-9.5, RF-9.6.
  """
  use EthWeb, :live_view

  alias Eth.{
    Accounts,
    Characters,
    ConfigTransfer,
    GameRules,
    Market,
    Notifications,
    Routing,
    Sde,
    Sso
  }

  alias Eth.Characters.{Pilot, Session, Sessions, ShipProfile}
  alias EthWeb.{Format, HunterParams}

  @tabs [
    characters: {"Personajes", "/settings"},
    ships: {"Naves", "/settings/ships"},
    rules: {"Reglas", "/settings/rules"},
    radar: {"Radar", "/settings/radar"},
    markets: {"Regiones y estructuras", "/settings/markets"},
    notifications: {"Notificaciones", "/settings/notifications"},
    setup: {"Primer arranque", "/settings/setup"},
    backup: {"Respaldo", "/settings/backup"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      for c <- socket.assigns.characters,
          do: Phoenix.PubSub.subscribe(Eth.PubSub, Session.topic(c.id))
    end

    {:ok,
     socket
     |> assign(:page_title, gettext("Ajustes"))
     |> assign(:tabs, @tabs)
     |> assign(:editing, nil)
     |> allow_upload(:config, accept: ~w(.json), max_entries: 1, max_file_size: 1_000_000)}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, socket |> assign(:editing, nil) |> load(socket.assigns.live_action)}
  end

  defp load(socket, :characters) do
    assign(socket, :rows, character_rows())
  end

  defp load(socket, :ships) do
    assign(socket, :profiles, Enum.map(Characters.list_ship_profiles(), &profile_row/1))
  end

  defp load(socket, :rules) do
    overrides = Accounts.game_rule_overrides()

    rules =
      for {key, label} <- GameRules.overridable() do
        %{
          key: key,
          label: label,
          default: GameRules.default(key),
          override: Map.get(overrides, key)
        }
      end

    form =
      rules
      |> Map.new(&{Atom.to_string(&1.key), (&1.override && percent_input(&1.override)) || ""})
      |> to_form(as: :rules)

    socket
    |> assign(:rules, rules)
    |> assign(:rules_form, form)
    |> assign(:verified_on, GameRules.get(:rules_verified_on, nil))
  end

  defp load(socket, :notifications) do
    rule = Notifications.rule()

    form =
      to_form(
        %{
          "enabled" => to_string(rule.enabled),
          "min_tvs" => Integer.to_string(rule.min_tvs),
          "min_profit" => HunterParams.format_isk(rule.min_profit)
        },
        as: :rule
      )

    assign(socket, :rule_form, form)
  end

  defp load(socket, :markets) do
    socket
    |> assign(:regions, Enum.sort_by(Market.region_statuses(), &{tier_order(&1.tier), &1.name}))
    |> assign(:structures, Market.structures())
    |> assign(:character_names, Map.new(socket.assigns.characters, &{&1.id, &1.name}))
    |> assign(:add_form, to_form(%{"id" => ""}, as: :structure))
  end

  defp load(socket, :radar) do
    settings = Accounts.radar_settings()

    form =
      to_form(
        %{
          "evasive_alpha" =>
            (settings.evasive_alpha && format_number(settings.evasive_alpha)) || "",
          "avoid" => Enum.map_join(settings.avoid_system_ids, ", ", &system_name/1)
        },
        as: :radar
      )

    socket
    |> assign(:radar_form, form)
    |> assign(:radar_settings, settings)
    |> assign(:alpha_default, GameRules.default(:evasive_alpha))
  end

  defp load(socket, :setup), do: assign(socket, :checks, setup_checks(socket.assigns.pilot))

  defp load(socket, :backup), do: assign_new(socket, :import_result, fn -> nil end)

  ## Respaldo (RF-9.7)

  @impl true
  def handle_event("validate_import", _params, socket), do: {:noreply, socket}

  # `path` es el archivo temporal que crea LiveView para la subida (nunca un dato del
  # usuario): no hay traversal posible.
  # sobelow_skip ["Traversal.FileModule"]
  def handle_event("import", _params, socket) do
    results =
      consume_uploaded_entries(socket, :config, fn %{path: path}, _entry ->
        {:ok, path |> File.read!() |> Jason.decode()}
      end)

    result =
      case results do
        [{:ok, config}] -> ConfigTransfer.import(config)
        [{:error, _}] -> {:error, gettext("El archivo no es un JSON válido.")}
        [] -> {:error, gettext("Elegí un archivo para importar.")}
      end

    {:noreply, assign(socket, :import_result, result)}
  end

  ## Personajes (RF-9.2)

  def handle_event("forget", %{"id" => id}, socket) do
    with {id, ""} <- Integer.parse(id),
         %{} = character <- Characters.get(id) do
      :ok = Characters.forget(character.id)

      socket = put_flash(socket, :info, gettext("%{name} fue olvidado", name: character.name))

      # Si era el personaje activo, se recarga la página en modo invitado.
      if socket.assigns.pilot && socket.assigns.pilot.id == character.id,
        do: {:noreply, redirect(socket, to: ~p"/settings")},
        else: {:noreply, socket |> assign(:characters, Characters.list()) |> load(:characters)}
    else
      _ -> {:noreply, socket}
    end
  end

  ## Naves (RF-9.3)

  def handle_event("edit_ship", %{"id" => id}, socket) do
    case find_profile(id) do
      nil ->
        {:noreply, socket}

      profile ->
        form = profile |> Characters.edit_ship_profile() |> to_form()
        {:noreply, assign(socket, editing: profile.id, ship_edit_form: form)}
    end
  end

  def handle_event("cancel_edit", _params, socket), do: {:noreply, assign(socket, :editing, nil)}

  def handle_event("validate_ship", %{"ship_profile" => params}, socket) do
    case find_profile(socket.assigns.editing) do
      nil ->
        {:noreply, socket}

      profile ->
        form =
          profile
          |> Characters.edit_ship_profile(params)
          |> Map.put(:action, :validate)
          |> to_form()

        {:noreply, assign(socket, :ship_edit_form, form)}
    end
  end

  def handle_event("save_ship", %{"ship_profile" => params}, socket) do
    with %ShipProfile{} = profile <- find_profile(socket.assigns.editing),
         {:ok, _profile} <- Characters.update_ship_profile(profile, params) do
      {:noreply,
       socket
       |> put_flash(:info, gettext("Perfil actualizado"))
       |> assign(:editing, nil)
       |> load(:ships)
       |> refresh_pilot()}
    else
      {:error, changeset} -> {:noreply, assign(socket, :ship_edit_form, to_form(changeset))}
      nil -> {:noreply, socket}
    end
  end

  def handle_event("delete_ship", %{"id" => id}, socket) do
    case find_profile(id) do
      nil ->
        {:noreply, socket}

      profile ->
        :ok = Characters.delete_ship_profile(profile)

        {:noreply,
         socket
         |> put_flash(:info, gettext("Perfil borrado"))
         |> assign(:editing, nil)
         |> load(:ships)
         |> refresh_pilot()}
    end
  end

  ## Reglas (RF-9.4)

  def handle_event("save_rules", %{"rules" => params}, socket) do
    results =
      for {key, _label} <- GameRules.overridable() do
        case parse_percent(params[Atom.to_string(key)]) do
          :blank -> Accounts.reset_game_rule(key)
          {:ok, value} -> Accounts.put_game_rule(key, value)
          :error -> {:error, :invalid_value}
        end
      end

    socket =
      if Enum.all?(results, &(&1 == :ok)),
        do: put_flash(socket, :info, gettext("Reglas guardadas: el mercado se vuelve a evaluar")),
        else:
          put_flash(
            socket,
            :error,
            gettext("Algún valor no es válido: usá un porcentaje entre 0 y 100")
          )

    {:noreply, load(socket, :rules)}
  end

  def handle_event("reset_rule", %{"key" => key}, socket) do
    case Enum.find(GameRules.overridable(), fn {k, _label} -> Atom.to_string(k) == key end) do
      {k, _label} ->
        :ok = Accounts.reset_game_rule(k)
        {:noreply, socket |> put_flash(:info, gettext("Regla restablecida")) |> load(:rules)}

      nil ->
        {:noreply, socket}
    end
  end

  ## Notificaciones (RF-10.2, RF-10.3)

  def handle_event("save_rule", %{"rule" => params}, socket) do
    attrs = %{
      enabled: params["enabled"] == "true",
      min_tvs: parse_int(params["min_tvs"]),
      min_profit: HunterParams.parse_isk(params["min_profit"])
    }

    case Notifications.put_rule(attrs) do
      :ok ->
        {:noreply,
         socket |> put_flash(:info, gettext("Regla de alertas guardada")) |> load(:notifications)}

      {:error, _} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("TVS entre 0 y 100 y un beneficio válido (por ejemplo 20M)")
         )}
    end
  end

  def handle_event("test_alert", _params, socket) do
    Notifications.notify(%{
      key: "test:#{System.unique_integer([:positive])}",
      title: gettext("Alerta de prueba"),
      body: gettext("Así se ven las notificaciones de EVE Trade Hunter"),
      url: "/settings/notifications"
    })

    {:noreply, socket}
  end

  ## Regiones y estructuras (RF-9.6)

  def handle_event("add_structure", %{"structure" => %{"id" => text}}, socket) do
    case Integer.parse(String.trim(text)) do
      {id, ""} when id > 0 ->
        :ok = Market.follow_structure(id)

        {:noreply,
         socket
         |> put_flash(:info, gettext("Estructura agregada: se resuelve con el próximo ciclo"))
         |> load(:markets)}

      _ ->
        {:noreply,
         put_flash(socket, :error, gettext("El ID de estructura tiene que ser un número"))}
    end
  end

  def handle_event("toggle_follow", %{"id" => id}, socket) do
    id = String.to_integer(id)
    row = Enum.find(socket.assigns.structures, &(&1.structure.id == id))
    if row, do: Market.update_structure(id, %{followed: not row.structure.followed})
    {:noreply, load(socket, :markets)}
  end

  def handle_event("save_broker_fee", %{"structure_id" => id, "fee" => text}, socket) do
    fee =
      case parse_percent(text) do
        :blank -> {:ok, nil}
        {:ok, value} -> {:ok, value}
        :error -> :error
      end

    case fee do
      {:ok, value} ->
        :ok = Market.update_structure(String.to_integer(id), %{broker_fee_override: value})
        {:noreply, socket |> put_flash(:info, gettext("Broker fee guardado")) |> load(:markets)}

      :error ->
        {:noreply, put_flash(socket, :error, gettext("Usá un porcentaje entre 0 y 100"))}
    end
  end

  ## Radar (RF-9.5)

  def handle_event("save_radar", %{"radar" => params}, socket) do
    names =
      (params["avoid"] || "")
      |> String.split([",", "
"],
        trim: true
      )
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    resolved = Enum.map(names, &{&1, Sde.system_by_name(&1)})
    unknown = for {name, nil} <- resolved, do: name
    alpha = parse_alpha(params["evasive_alpha"])

    cond do
      unknown != [] ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Sistemas desconocidos: %{names}", names: Enum.join(unknown, ", "))
         )}

      alpha == :error ->
        {:noreply, put_flash(socket, :error, gettext("α tiene que ser un número entre 0 y 100"))}

      true ->
        ids = for {_name, {id, _system}} <- resolved, do: id

        case Accounts.put_radar_settings(alpha, ids) do
          :ok ->
            {:noreply,
             socket
             |> put_flash(:info, gettext("Radar guardado: el mercado se vuelve a evaluar"))
             |> load(:radar)}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, gettext("Algún valor no es válido"))}
        end
    end
  end

  defp tier_label(:hub), do: gettext("N1 · hub")
  defp tier_label(:active), do: gettext("N2 · activa")
  defp tier_label(_rest), do: gettext("N3 · resto")

  defp access_label("ok"), do: gettext("con acceso")
  defp access_label("forbidden"), do: gettext("sin acceso (403)")
  defp access_label(_unknown), do: gettext("sin probar")

  defp tier_order(:hub), do: 0
  defp tier_order(:active), do: 1
  defp tier_order(_rest), do: 2

  defp parse_int(text) do
    case Integer.parse(String.trim(text || "")) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_alpha(text) do
    case Float.parse(String.replace(String.trim(text || ""), ",", ".")) do
      :error -> if String.trim(text || "") == "", do: nil, else: :error
      {n, ""} when n >= 0 and n <= 100 -> n
      _ -> :error
    end
  end

  defp system_name(id), do: (Sde.system(id) || %{name: "#{id}"}).name

  defp format_number(n) when n == trunc(n), do: Integer.to_string(trunc(n))
  defp format_number(n), do: Float.to_string(n)

  # Cambios en una sesión de personaje (el piloto lo actualiza EthWeb.PilotHook).
  @impl true
  def handle_info({:character, _id, _event, _public}, socket) do
    case socket.assigns.live_action do
      :characters -> {:noreply, load(socket, :characters)}
      :setup -> {:noreply, load(socket, :setup)}
      _ -> {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  ## Datos

  defp character_rows do
    for c <- Characters.list() do
      session = Sessions.context(c.id)
      granted = (session && session.scopes) || c.scopes

      %{
        character: c,
        session: session,
        missing_scopes: Sso.missing_scopes(granted),
        portrait_url: Pilot.portrait_url(c.id, 64)
      }
    end
  end

  defp profile_row(profile) do
    type = Sde.type(profile.ship_type_id)
    %{profile: profile, type_name: (type && type.name) || "#{profile.ship_type_id}"}
  end

  defp find_profile(nil), do: nil

  defp find_profile(id) when is_binary(id) do
    case Integer.parse(id) do
      {id, ""} -> Characters.get_ship_profile(id)
      _ -> nil
    end
  end

  defp find_profile(id), do: Characters.get_ship_profile(id)

  # El piloto puede usar el perfil editado: se rearma con el contexto vigente.
  defp refresh_pilot(%{assigns: %{pilot: %{id: id}}} = socket) do
    send(self(), {:character, id, :ship_profile, Sessions.context(id)})
    socket
  end

  defp refresh_pilot(socket), do: socket

  # Checklist del primer arranque (RF-9.1): {id, título, ¿ok?, ayuda}.
  defp setup_checks(pilot) do
    characters = Characters.list()
    regions = Market.region_statuses()

    [
      {:env, gettext("Variables de entorno (SSO y clave de cifrado)"), Sso.configured?(),
       gettext("Definí EVE_CLIENT_ID, EVE_CLIENT_SECRET y ETH_VAULT_KEY en .env y reiniciá.")},
      {:sso, gettext("Aplicación SSO registrada (prueba de login)"), characters != [],
       gettext(
         "Iniciá sesión con EVE: si falla, revisá el callback y los scopes de la aplicación."
       )},
      {:sde, gettext("SDE descargado"), Sde.ready?(),
       gettext("Se descarga solo al arrancar (≈ 100 MB); mirá el Centro de control.")},
      {:graph, gettext("Grafo de rutas construido"), Routing.graph() != nil,
       gettext("Se construye con el SDE.")},
      {:scan, gettext("Primer escaneo de los hubs"), Enum.any?(regions, &(&1.generation > 0)),
       gettext("Los pollers de mercado descargan las regiones; puede tardar unos minutos.")},
      {:character, gettext("Personaje activo con sesión en EVE"),
       pilot != nil and pilot.status == :ok,
       gettext("Elegí un personaje en el menú de la cabecera.")},
      {:ship, gettext("Bodega de la nave actual confirmada"),
       pilot != nil and pilot.ship != nil and pilot.ship.cargo_confirmed,
       gettext(
         "Con el permiso de assets se calcula sola; si no, confirmala desde la barra del piloto."
       )}
    ]
  end

  ## Presentación

  @doc false
  @spec percent_input(float()) :: String.t()
  def percent_input(value), do: value |> Kernel.*(100) |> Float.round(6) |> Float.to_string()

  @doc false
  # Porcentaje escrito por el usuario ("7,5" o "7.5") a proporción; vacío = sin override.
  @spec parse_percent(String.t() | nil) :: {:ok, float()} | :blank | :error
  def parse_percent(nil), do: :blank

  def parse_percent(text) do
    case text |> String.trim() |> String.replace(",", ".") do
      "" ->
        :blank

      clean ->
        case Float.parse(clean) do
          {n, ""} when n >= 0 and n <= 100 -> {:ok, n / 100}
          _ -> :error
        end
    end
  end

  defp pct(value), do: "#{value |> Kernel.*(100) |> Float.round(4)} %"

  defp status_label(nil, %{token_status: "relogin"}), do: gettext("Re-login requerido")
  defp status_label(nil, _character), do: gettext("Sin sesión")
  defp status_label(%{status: :ok}, _character), do: gettext("Sesión activa")
  defp status_label(%{status: :relogin}, _character), do: gettext("Re-login requerido")
  defp status_label(%{status: :token_error}, _character), do: gettext("Error de token")
  defp status_label(_session, _character), do: gettext("Conectando…")

  defp status_class(%{status: :ok}), do: "badge-success"
  defp status_class(%{status: :relogin}), do: "badge-warning"
  defp status_class(%{status: :token_error}), do: "badge-error"
  defp status_class(_session), do: "badge-ghost"

  defp mode_label(:active), do: gettext("polling activo")
  defp mode_label(:idle), do: gettext("en línea, sin UI")
  defp mode_label(:offline), do: gettext("offline, polling reducido")
  defp mode_label(_mode), do: ""

  defp evasion_label(class) do
    Map.get(
      %{
        "industrial" => gettext("Industrial"),
        "blockade_runner" => gettext("Blockade Runner"),
        "deep_space_transport" => gettext("Deep Space Transport"),
        "freighter" => gettext("Freighter"),
        "shuttle" => gettext("Shuttle"),
        "other" => gettext("Otra")
      },
      class,
      class
    )
  end

  defp evasion_options do
    for class <- ShipProfile.evasion_classes(), do: {evasion_label(class), class}
  end
end
