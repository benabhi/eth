defmodule EthWeb.Layouts do
  @moduledoc """
  Layouts de la aplicación: estructura común, navegación principal, mensajes flash
  y selector de tema claro/oscuro/sistema.

  Implementa: RF-6.11, RNF-5.1, RNF-5.2.
  """
  use EthWeb, :html

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
      <div class="flex-none">
        <.theme_toggle />
      </div>
    </header>

    <main class="px-4 py-10 sm:px-6 lg:px-8">
      <div class="mx-auto max-w-5xl space-y-6">
        {render_slot(@inner_block)}
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end

  # Secciones de la navegación (ERS §9.2); las que aún no existen se muestran deshabilitadas.
  defp sections do
    [
      {:hunter, gettext("Cazador"), ~p"/"},
      {:run, gettext("Viaje activo"), nil},
      {:control, gettext("Centro de control"), nil},
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
