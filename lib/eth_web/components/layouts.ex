defmodule EthWeb.Layouts do
  @moduledoc """
  Layouts de la aplicación: estructura común, navegación principal, mensajes flash
  y selector de tema claro/oscuro/sistema.

  Implementa: RF-6.11, RNF-5.1, RNF-5.2.
  """
  use EthWeb, :html

  alias Eth.Characters.Pilot
  alias Eth.{GameRules, Sde}
  alias EthWeb.Format

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Layout principal de la aplicación: barra superior con la navegación (ERS §9.2),
  selector de tema y contenido.

  ## Ejemplo

      <Layouts.app flash={@flash} active={:hunter}>
        <h1>Contenido</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "mensajes flash"

  attr :current_scope, :map,
    default: nil,
    doc: "scope actual de la sesión"

  attr :active, :atom, default: nil, doc: "sección activa de la navegación"
  attr :pilot, :map, default: nil, doc: "piloto activo (`EthWeb.PilotHook`); `nil` = invitado"
  attr :characters, :list, default: [], doc: "personajes vinculados (selector)"
  attr :ship_form, :any, default: nil, doc: "formulario del perfil de carga abierto (RF-5.8)"
  attr :wide, :boolean, default: false, doc: "contenedor ancho (tableros)"

  slot :inner_block, required: true

  def app(assigns) do
    assigns = assign(assigns, :sections, sections())

    ~H"""
    <header class="navbar border-b border-base-300 px-4 sm:px-6 lg:px-8">
      <div class="flex-1 items-center gap-6">
        <a href={~p"/"} class="text-lg font-bold tracking-wide">EVE Trade Hunter</a>
        <nav aria-label={gettext("Navegación principal")}>
          <ul class="menu menu-horizontal gap-1 p-0">
            <li :for={{id, label, path} <- @sections}>
              <a
                :if={path}
                href={path}
                class={[@active == id && "menu-active"]}
                aria-current={@active == id && "page"}
              >
                {label}
              </a>
              <span
                :if={!path}
                class="menu-disabled opacity-50 cursor-not-allowed"
                title={gettext("Próximamente")}
              >
                {label}
              </span>
            </li>
          </ul>
        </nav>
      </div>
      <div class="flex flex-none items-center gap-3">
        <.character_menu pilot={@pilot} characters={@characters} />
        <.theme_toggle />
      </div>
    </header>

    <.pilot_bar :if={@pilot} pilot={@pilot} />
    <.ship_dialog :if={@pilot && @pilot.ship && @ship_form} pilot={@pilot} form={@ship_form} />

    <main class="px-4 py-6 sm:px-6 lg:px-8">
      <div class={["mx-auto space-y-6", if(@wide, do: "max-w-screen-2xl", else: "max-w-5xl")]}>
        {render_slot(@inner_block)}
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end

  @doc "Selector de personaje, login con EVE SSO y cierre de sesión (RF-5.1, RF-5.10)."
  attr :pilot, :map, default: nil
  attr :characters, :list, default: []

  def character_menu(%{pilot: nil} = assigns) do
    ~H"""
    <div class="flex items-center gap-2">
      <details :if={@characters != []} id="character-menu" class="dropdown dropdown-end">
        <summary class="btn btn-ghost btn-sm">{gettext("Personajes")}</summary>
        <.character_list characters={@characters} />
      </details>
      <a id="login-eve" href={~p"/auth/eve"} class="btn btn-primary btn-sm">
        <.icon name="hero-arrow-right-end-on-rectangle" class="size-4" />
        {gettext("Iniciar sesión con EVE")}
      </a>
    </div>
    """
  end

  def character_menu(assigns) do
    ~H"""
    <details id="character-menu" class="dropdown dropdown-end">
      <summary class="btn btn-ghost btn-sm gap-2 px-1.5">
        <span class="relative">
          <img
            src={@pilot.portrait_url}
            alt=""
            width="32"
            height="32"
            class="size-8 rounded-full ring-1 ring-base-300"
          />
          <span
            class={[
              "absolute -bottom-0.5 -right-0.5 size-3 rounded-full ring-2 ring-base-100",
              online_class(@pilot.online)
            ]}
            title={online_label(@pilot.online)}
          ></span>
        </span>
        <span id="pilot-name" class="max-w-40 truncate">{@pilot.name}</span>
      </summary>
      <.character_list characters={@characters} active_id={@pilot.id} />
    </details>
    """
  end

  attr :characters, :list, required: true
  attr :active_id, :integer, default: nil

  defp character_list(assigns) do
    ~H"""
    <ul class="menu dropdown-content z-20 mt-2 w-64 rounded-box border border-base-300 bg-base-100 p-2 shadow-lg">
      <li :for={c <- @characters}>
        <.link
          id={"activate-#{c.id}"}
          href={~p"/auth/characters/#{c.id}/activate"}
          method="post"
          class={[c.id == @active_id && "menu-active"]}
        >
          <img
            src={Pilot.portrait_url(c.id, 32)}
            alt=""
            width="24"
            height="24"
            class="size-6 rounded-full"
          />
          <span class="truncate">{c.name}</span>
          <span :if={c.token_status == "relogin"} class="badge badge-warning badge-xs">
            {gettext("re-login")}
          </span>
        </.link>
      </li>
      <li>
        <a href={~p"/auth/eve"}>
          <.icon name="hero-user-plus" class="size-4" /> {gettext("Agregar personaje")}
        </a>
      </li>
      <li :if={@active_id}>
        <.link id="logout" href={~p"/auth/logout"} method="post">
          <.icon name="hero-arrow-left-start-on-rectangle" class="size-4" />
          {gettext("Modo invitado")}
        </.link>
      </li>
    </ul>
    """
  end

  @doc "Barra de contexto del piloto (RF-6.1): billetera, nave, ubicación e impuestos."
  attr :pilot, :map, required: true

  def pilot_bar(assigns) do
    ~H"""
    <section
      id="pilot-bar"
      aria-label={gettext("Contexto del piloto")}
      class="border-b border-base-300 bg-base-200/60 px-4 py-2 text-sm sm:px-6 lg:px-8"
    >
      <div
        :if={@pilot.status == :relogin}
        id="pilot-relogin"
        role="alert"
        class="alert alert-warning mb-2 py-2"
      >
        <.icon name="hero-exclamation-triangle" class="size-5" />
        <span>
          {gettext("La autorización de EVE de %{name} venció o fue revocada.", name: @pilot.name)}
        </span>
        <a href={~p"/auth/eve"} class="btn btn-sm">{gettext("Volver a iniciar sesión")}</a>
      </div>

      <div class="flex flex-wrap items-center gap-x-6 gap-y-2 tabular-nums">
        <div id="pilot-wallet" class="flex items-center gap-2" title={gettext("Billetera")}>
          <.icon name="hero-wallet" class="size-4 text-base-content/60" />
          <span class="font-semibold">{Format.compact(@pilot.wallet)} ISK</span>
        </div>

        <div :if={ship = @pilot.ship} id="pilot-ship" class="flex items-center gap-2">
          <img
            src={ship.render_url}
            alt=""
            width="32"
            height="32"
            class="size-8 rounded bg-base-300"
          />
          <div class="leading-tight">
            <div>
              <span class="font-semibold">{ship.type_name}</span>
              <span :if={ship.ship_name} class="text-base-content/60">· {ship.ship_name}</span>
            </div>
            <div class="text-xs text-base-content/70">
              <%= if ship.cargo_m3 do %>
                {gettext("Bodega %{m3} m³", m3: Format.integer(round(ship.cargo_m3)))}
              <% else %>
                {gettext("Bodega desconocida")}
              <% end %>
              <button
                id="ship-profile-open"
                type="button"
                phx-click="pilot_ship_open"
                title={cargo_source_hint(ship, @pilot)}
                class={["badge badge-xs ml-1 cursor-pointer", cargo_source_class(ship.cargo_source)]}
              >
                {cargo_source_label(ship.cargo_source)}
              </button>
            </div>
          </div>
        </div>

        <div :if={loc = @pilot.location} id="pilot-location" class="flex items-center gap-2">
          <.icon name="hero-map-pin" class="size-4 text-base-content/60" />
          <span>
            <span class="font-semibold">{loc.system_name}</span>
            <span :if={loc.security} style={"color: #{Sde.security_color(loc.security)}"}>
              {:erlang.float_to_binary(Sde.security_display(loc.security), decimals: 1)}
            </span>
            <span :if={loc.docked_name} class="text-base-content/60">
              · {loc.docked_name}
            </span>
            <span :if={loc.in_structure} class="text-base-content/60">
              · {gettext("en estructura")}
            </span>
          </span>
        </div>

        <div
          :if={@pilot.sales_tax}
          id="pilot-tax"
          class="flex items-center gap-2"
          title={tax_tooltip(@pilot.accounting)}
        >
          <.icon name="hero-receipt-percent" class="size-4 text-base-content/60" />
          {gettext("Sales tax %{pct}", pct: percent(@pilot.sales_tax))}
          <span class="text-base-content/60">(Accounting {@pilot.accounting})</span>
        </div>

        <div
          :if={@pilot.status in [:starting, :token_error]}
          class="flex items-center gap-2 text-base-content/60"
        >
          <.icon name="hero-arrow-path" class="size-4 motion-safe:animate-spin" />
          {gettext("Conectando con EVE…")}
        </div>
      </div>
    </section>
    """
  end

  @doc "Diálogo no bloqueante del perfil de carga de la nave activa (RF-5.8)."
  attr :pilot, :map, required: true
  attr :form, :any, required: true

  def ship_dialog(assigns) do
    ~H"""
    <section id="ship-dialog" aria-labelledby="ship-dialog-title" class="mx-4 mt-4 sm:mx-6 lg:mx-8">
      <div class="card mx-auto max-w-2xl border border-warning/40 bg-base-100 p-4 shadow-lg">
        <div class="flex items-start justify-between gap-4">
          <div>
            <h2 id="ship-dialog-title" class="font-semibold">
              {gettext("Perfil de carga: %{ship}", ship: @pilot.ship.type_name)}
            </h2>
            <p class="text-sm text-base-content/70">
              {gettext(
                "Capacidad de la bodega general con tus habilidades y módulos. Las bodegas especializadas (mineral, PI, combustible…) no cuentan."
              )}
            </p>
          </div>
          <button
            id="ship-dialog-close"
            type="button"
            phx-click="pilot_ship_close"
            class="btn btn-ghost btn-sm btn-circle"
            aria-label={gettext("Cerrar")}
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </div>

        <.form
          for={@form}
          id="ship-profile-form"
          phx-change="pilot_ship_validate"
          phx-submit="pilot_ship_save"
          class="mt-2 grid grid-cols-1 gap-x-3 sm:grid-cols-3"
        >
          <.input
            field={@form[:cargo_m3]}
            type="number"
            step="any"
            min="0"
            label={gettext("Bodega general (m³)")}
          />
          <.input
            field={@form[:evasion_class]}
            type="select"
            label={gettext("Clase de evasión")}
            options={evasion_options()}
          />
          <.input
            field={@form[:max_cargo_value]}
            type="number"
            step="any"
            min="0"
            label={gettext("Valor máx. de carga (opcional)")}
          />
          <div class="sm:col-span-3">
            <.input
              id="ship-profile-apply-to-hull"
              name="ship_profile[apply_to_hull]"
              type="checkbox"
              label={
                gettext("Usar este perfil para mis otras %{ship} sin perfil propio",
                  ship: @pilot.ship.type_name
                )
              }
            />
          </div>
          <div class="sm:col-span-3">
            <button id="ship-profile-save" type="submit" class="btn btn-primary btn-sm">
              {gettext("Guardar perfil")}
            </button>
          </div>
        </.form>
      </div>
    </section>
    """
  end

  defp evasion_options do
    [
      {gettext("Industrial"), "industrial"},
      {gettext("Blockade Runner"), "blockade_runner"},
      {gettext("Deep Space Transport"), "deep_space_transport"},
      {gettext("Freighter"), "freighter"},
      {gettext("Shuttle"), "shuttle"},
      {gettext("Otra"), "other"}
    ]
  end

  defp cargo_source_label(:fitting), do: gettext("calculada")
  defp cargo_source_label(:profile), do: gettext("manual")
  defp cargo_source_label(:skills), do: gettext("estimada")
  defp cargo_source_label(_sde), do: gettext("Capacidad sin confirmar")

  defp cargo_source_class(:fitting), do: "badge-success"
  defp cargo_source_class(:profile), do: "badge-ghost"
  defp cargo_source_class(:skills), do: "badge-info"
  defp cargo_source_class(_sde), do: "badge-warning"

  defp cargo_source_hint(%{cargo_source: :fitting} = ship, _pilot) do
    gettext(
      "Casco + habilidades + %{count} módulos montados. ESI informa los módulos cada hora.",
      count: ship.fitted_modules
    )
  end

  defp cargo_source_hint(%{cargo_source: :profile}, _pilot),
    do: gettext("Perfil guardado a mano: se usa mientras no se puedan leer los módulos.")

  defp cargo_source_hint(%{cargo_source: :skills}, pilot) do
    if Pilot.scope?(pilot, "esi-assets.read_assets.v1"),
      do: gettext("Casco + habilidades; ESI todavía no informó los módulos de esta nave."),
      else:
        gettext(
          "Casco + habilidades. Para sumar los módulos, volvé a iniciar sesión y concedé el permiso de assets."
        )
  end

  defp cargo_source_hint(_ship, _pilot),
    do: gettext("Capacidad base del casco, sin habilidades ni módulos: confirmala.")

  defp online_class(true), do: "bg-success"
  defp online_class(false), do: "bg-base-content/30"
  defp online_class(nil), do: "bg-warning"

  defp online_label(true), do: gettext("En línea")
  defp online_label(false), do: gettext("Desconectado")
  defp online_label(nil), do: gettext("Estado desconocido")

  defp percent(x), do: "#{:erlang.float_to_binary(x * 100, decimals: 2)} %"

  defp tax_tooltip(level) do
    gettext("%{base} × (1 − %{per} × Accounting %{level})",
      base: percent(GameRules.get(:sales_tax_base)),
      per: GameRules.get(:accounting_reduction_per_level),
      level: level
    )
  end

  # Secciones de la navegación (ERS §9.2); las que aún no existen se muestran deshabilitadas.
  defp sections do
    [
      {:hunter, gettext("Cazador"), ~p"/"},
      {:run, gettext("Viaje activo"), nil},
      {:control, gettext("Centro de control"), ~p"/control"},
      {:settings, gettext("Ajustes"), nil}
    ]
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("Sin conexión a internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Intentando reconectar")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("¡Algo salió mal!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Intentando reconectar")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Selector de tema sistema/claro/oscuro basado en los temas de `app.css`.

  El `<head>` de `root.html.heex` aplica el tema antes de pintar la página (sin parpadeo).
  """
  def theme_toggle(assigns) do
    ~H"""
    <div
      class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full"
      role="group"
      aria-label={gettext("Tema")}
    >
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 [[data-theme-source=system]_&]:!left-0 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
        aria-label={gettext("Tema del sistema")}
        title={gettext("Tema del sistema")}
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
        aria-label={gettext("Tema claro")}
        title={gettext("Tema claro")}
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
        aria-label={gettext("Tema oscuro")}
        title={gettext("Tema oscuro")}
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
