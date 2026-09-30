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
  attr :radar_degraded, :boolean, default: false, doc: "radar sin feed en vivo (RF-3.8)"

  slot :inner_block, required: true

  def app(assigns) do
    assigns = assign(assigns, :sections, sections())

    ~H"""
    <%!-- Tooltips dentro de la pantalla: al abrirse se corren si se salían (RNF-5.14). --%>
    <div id="tip-clamp" phx-hook=".TipClamp" hidden></div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".TipClamp">
      export default {
        mounted() {
          this.fit = (e) => {
            const tip = e.target.closest && e.target.closest(".eth-tip")
            const body = tip && tip.querySelector(":scope > .eth-tip-body")
            if (!body) return
            body.style.setProperty("--eth-tip-shift", "0px")
            const r = body.getBoundingClientRect()
            const margin = 8
            // Límites: la ventana y el contenedor más cercano que recorta (overflow).
            let min = margin, max = window.innerWidth - margin
            for (let el = tip.parentElement; el && el !== document.body; el = el.parentElement) {
              const cs = getComputedStyle(el)
              if (cs.overflowX !== "visible" || cs.clipPath !== "none") {
                const b = el.getBoundingClientRect()
                min = Math.max(min, b.left + margin)
                max = Math.min(max, b.right - margin)
                break
              }
            }
            let shift = 0
            if (r.left < min) shift = min - r.left
            else if (r.right > max) shift = max - r.right
            body.style.setProperty("--eth-tip-shift", `${Math.round(shift)}px`)
          }
          document.addEventListener("pointerover", this.fit, true)
          document.addEventListener("focusin", this.fit, true)
        },
        destroyed() {
          document.removeEventListener("pointerover", this.fit, true)
          document.removeEventListener("focusin", this.fit, true)
        }
      }
    </script>
    <header class="sticky top-0 z-30 border-b border-base-300 bg-base-200/95 backdrop-blur">
      <div class="flex h-14 items-center gap-4 px-4 lg:gap-7 lg:px-7">
        <.link navigate={~p"/"} class="flex items-center gap-2.5" aria-label="EVE Trade Hunter">
          <svg width="24" height="24" viewBox="0 0 26 26" aria-hidden="true" class="text-primary">
            <path
              d="M13 2 L24 8 L24 18 L13 24 L2 18 L2 8 Z"
              fill="none"
              stroke="currentColor"
              stroke-width="1.5"
            />
            <path d="M13 7 L19 13 L13 19 L7 13 Z" fill="currentColor" opacity="0.85" />
          </svg>
          <span class="hidden font-display text-[15px] font-bold tracking-[0.14em] eth-strong sm:inline">
            TRADE HUNTER
          </span>
        </.link>
        <nav aria-label={gettext("Navegación principal")} class="hidden h-14 md:flex">
          <%= for {id, label, path} <- @sections do %>
            <.link
              navigate={path}
              aria-current={@active == id && "page"}
              class={[
                "flex items-center border-b-2 px-3 font-display text-[13px] tracking-[0.12em] uppercase transition-colors lg:px-4",
                if(@active == id,
                  do: "border-primary eth-strong",
                  else: "border-transparent eth-muted hover:text-base-content"
                )
              ]}
            >
              {label}
            </.link>
          <% end %>
        </nav>
        <div class="flex-1"></div>
        <.link
          :if={@radar_degraded}
          id="radar-degraded"
          navigate={~p"/control/radar"}
          class="hidden items-center gap-1.5 border border-warning/60 px-2 py-1 text-xs text-warning sm:flex"
          title={
            gettext(
              "Sin kills del feed en vivo: el riesgo de ruta usa solo lo habitual de cada sistema (línea base)"
            )
          }
        >
          <.icon name="hero-signal-slash" class="size-3.5" /> {gettext("Radar degradado")}
        </.link>
        <.character_menu pilot={@pilot} characters={@characters} />
        <.theme_toggle />
      </div>
    </header>

    <.pilot_bar :if={@pilot} pilot={@pilot} />
    <.ship_dialog :if={@pilot && @pilot.ship && @ship_form} pilot={@pilot} form={@ship_form} />

    <main class="eth-grid-bg min-h-[calc(100vh-3.5rem)] px-4 pt-5 pb-24 sm:px-6 md:pb-8 lg:px-7">
      <div class={["mx-auto space-y-5", if(@wide, do: "max-w-[1600px]", else: "max-w-5xl")]}>
        {render_slot(@inner_block)}
      </div>
    </main>

    <%!-- Navegación inferior en el teléfono (RNF-5.4) --%>
    <nav
      aria-label={gettext("Navegación principal")}
      class="fixed inset-x-0 bottom-0 z-30 grid grid-cols-5 border-t border-base-300 bg-base-200/95 backdrop-blur md:hidden"
    >
      <.link
        :for={{id, label, path} <- @sections}
        navigate={path}
        aria-current={@active == id && "page"}
        class={[
          "flex h-16 flex-col items-center justify-center gap-1.5 text-[11px]",
          if(@active == id, do: "eth-strong", else: "eth-muted")
        ]}
      >
        <span class={["h-0.5 w-5", if(@active == id, do: "bg-primary", else: "bg-transparent")]}></span>
        {label}
      </.link>
    </nav>

    <.flash_group flash={@flash} />

    <%!-- Notificaciones del navegador y sonido (RF-10.2): opt-in por navegador --%>
    <div id="eth-notifier" phx-hook=".Notifier" class="hidden"></div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".Notifier">
      // Preferencias por navegador (localStorage): "eth-notify" y "eth-sound" = "on" | "off".
      const pref = (key) => localStorage.getItem(key) === "on"

      const describe = () => {
        const el = document.getElementById("notify-status")
        if (!el) return
        const permission = "Notification" in window ? Notification.permission : "unsupported"
        const browser =
          permission === "unsupported" ? "este navegador no las admite"
          : pref("eth-notify") && permission === "granted" ? "activadas"
          : permission === "denied" ? "bloqueadas en el navegador"
          : "desactivadas"
        el.textContent = `Notificaciones del navegador: ${browser} · Sonido: ${pref("eth-sound") ? "activado" : "desactivado"}`
      }

      // Tono corto con WebAudio: sin archivos de audio externos.
      const beep = () => {
        const Ctx = window.AudioContext || window.webkitAudioContext
        if (!Ctx) return
        const ctx = new Ctx()
        const osc = ctx.createOscillator()
        const gain = ctx.createGain()
        osc.frequency.value = 880
        gain.gain.setValueAtTime(0.08, ctx.currentTime)
        gain.gain.exponentialRampToValueAtTime(0.0001, ctx.currentTime + 0.25)
        osc.connect(gain).connect(ctx.destination)
        osc.start()
        osc.stop(ctx.currentTime + 0.25)
      }

      export default {
        mounted() {
          this.handleEvent("eth:notify", ({title, body, url}) => {
            if (pref("eth-sound")) beep()
            if (pref("eth-notify") && "Notification" in window && Notification.permission === "granted") {
              const n = new Notification(title, {body, tag: title})
              if (url) n.onclick = () => { window.focus(); window.location.href = url }
            }
          })

          this.onPermission = () => {
            if (!("Notification" in window)) return describe()
            Notification.requestPermission().then((p) => {
              localStorage.setItem("eth-notify", p === "granted" ? "on" : "off")
              describe()
            })
          }
          this.onDisable = () => { localStorage.setItem("eth-notify", "off"); describe() }
          this.onSound = () => {
            localStorage.setItem("eth-sound", pref("eth-sound") ? "off" : "on")
            if (pref("eth-sound")) beep()
            describe()
          }

          window.addEventListener("eth:notify-permission", this.onPermission)
          window.addEventListener("eth:notify-disable", this.onDisable)
          window.addEventListener("eth:notify-sound", this.onSound)
          describe()
        },
        updated() { describe() },
        destroyed() {
          window.removeEventListener("eth:notify-permission", this.onPermission)
          window.removeEventListener("eth:notify-disable", this.onDisable)
          window.removeEventListener("eth:notify-sound", this.onSound)
        }
      }
    </script>
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
      <a
        id="login-eve"
        href={~p"/auth/eve"}
        class="eth-chamfer-sm btn btn-primary btn-sm font-display tracking-wide"
      >
        <.icon name="hero-arrow-right-end-on-rectangle" class="size-4" />
        <span class="hidden sm:inline">{gettext("Iniciar sesión con EVE")}</span>
        <span class="sm:hidden">{gettext("Entrar")}</span>
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
            class="size-8 ring-1 ring-primary/60"
          />
          <span
            class={[
              "absolute -bottom-0.5 -right-0.5 size-3 rounded-full ring-2 ring-base-100",
              online_class(@pilot.online)
            ]}
            title={online_label(@pilot.online)}
          ></span>
        </span>
        <span id="pilot-name" class="hidden max-w-40 truncate sm:inline">{@pilot.name}</span>
      </summary>
      <.character_list characters={@characters} active_id={@pilot.id} />
    </details>
    """
  end

  attr :characters, :list, required: true
  attr :active_id, :integer, default: nil

  defp character_list(assigns) do
    ~H"""
    <ul class="eth-raised menu dropdown-content z-40 mt-2 w-64 p-2">
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
      class="border-b border-base-300 bg-base-100 px-4 py-2.5 text-sm sm:px-6 lg:px-7"
    >
      <div
        :if={@pilot.status == :relogin}
        id="pilot-relogin"
        role="alert"
        class="mb-2 flex flex-wrap items-center gap-3 border border-warning/50 bg-warning/10 px-3 py-2 text-warning"
      >
        <.icon name="hero-exclamation-triangle" class="size-5" />
        <span>
          {gettext("La autorización de EVE de %{name} venció o fue revocada.", name: @pilot.name)}
        </span>
        <a href={~p"/auth/eve"} class="btn btn-warning btn-sm">{gettext("Volver a iniciar sesión")}</a>
      </div>

      <div class="flex flex-wrap items-center gap-x-7 gap-y-2 tabular-nums">
        <div id="pilot-wallet" class="flex flex-col" title={gettext("Billetera")}>
          <span class="eth-kicker text-[10px]">{gettext("Billetera")}</span>
          <span class="font-mono eth-strong">{Format.compact(@pilot.wallet)} ISK</span>
        </div>

        <div :if={ship = @pilot.ship} id="pilot-ship" class="flex items-center gap-2">
          <img
            src={ship.render_url}
            alt=""
            width="32"
            height="32"
            class="size-9 bg-base-300"
          />
          <div class="leading-tight">
            <div>
              <span class="font-semibold eth-strong">{ship.type_name}</span>
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
                class={[
                  "badge badge-xs ml-1 cursor-pointer font-display tracking-wide",
                  cargo_source_class(ship.cargo_source)
                ]}
              >
                {cargo_source_label(ship.cargo_source)}
              </button>
            </div>
          </div>
        </div>

        <div :if={loc = @pilot.location} id="pilot-location" class="flex flex-col">
          <span class="eth-kicker text-[10px]">{gettext("Ubicación")}</span>
          <span>
            <span class="font-semibold eth-strong">{loc.system_name}</span>
            <span
              :if={loc.security}
              class="font-mono"
              style={"color: #{Sde.security_color(loc.security)}"}
            >
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

        <div :if={@pilot.sales_tax} id="pilot-tax" class="flex flex-col">
          <span class="eth-kicker text-[10px]">{gettext("Sales tax")}</span>
          <.tip title={gettext("Sales tax")} topic={:sales_tax} align="start">
            <span class="font-mono eth-strong">
              {gettext("Sales tax %{pct}", pct: percent(@pilot.sales_tax))}
            </span>
            <span class="eth-muted">(Accounting {@pilot.accounting})</span>
            <:body>{gettext("Impuesto al vender. Baja con tu nivel de Accounting.")}</:body>
            <:formula>{tax_tooltip(@pilot.accounting)} = {percent(@pilot.sales_tax)}</:formula>
          </.tip>
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
      <div class="eth-chamfer eth-raised mx-auto max-w-2xl p-4">
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

  # Secciones de la navegación (ERS §9.2).
  defp sections do
    [
      {:hunter, gettext("Tablón"), ~p"/"},
      {:run, gettext("Viaje"), ~p"/run"},
      {:control, gettext("Control"), ~p"/control"},
      {:settings, gettext("Ajustes"), ~p"/settings"},
      {:docs, gettext("Documentación"), ~p"/docs"}
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
        icon="hero-signal-slash"
        icon_class="motion-safe:animate-pulse"
        title={gettext("Sin conexión con el servidor")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        <span class="inline-flex items-center gap-1.5">
          <.icon name="hero-arrow-path" class="size-3.5 motion-safe:animate-spin" />
          {gettext("Intentando reconectar…")}
        </span>
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
        <span class="inline-flex items-center gap-1.5">
          <.icon name="hero-arrow-path" class="size-3.5 motion-safe:animate-spin" />
          {gettext("Intentando reconectar…")}
        </span>
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
    <div class="flex border border-base-300" role="group" aria-label={gettext("Tema")}>
      <button
        :for={
          {theme, icon, label} <- [
            {"system", "hero-computer-desktop-micro", gettext("Tema del sistema")},
            {"light", "hero-sun-micro", gettext("Modo día")},
            {"dark", "hero-moon-micro", gettext("Modo noche")}
          ]
        }
        type="button"
        class={[
          "flex cursor-pointer p-1.5 eth-muted hover:text-base-content",
          "[[data-theme-source=system]_&]:data-[phx-theme=system]:bg-primary",
          "[[data-theme-source=system]_&]:data-[phx-theme=system]:text-primary-content",
          "[[data-theme-source=user][data-theme=light]_&]:data-[phx-theme=light]:bg-primary",
          "[[data-theme-source=user][data-theme=light]_&]:data-[phx-theme=light]:text-primary-content",
          "[[data-theme-source=user][data-theme=dark]_&]:data-[phx-theme=dark]:bg-primary",
          "[[data-theme-source=user][data-theme=dark]_&]:data-[phx-theme=dark]:text-primary-content"
        ]}
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme={theme}
        aria-label={label}
        title={label}
      >
        <.icon name={icon} class="size-4" />
      </button>
    </div>
    """
  end
end
