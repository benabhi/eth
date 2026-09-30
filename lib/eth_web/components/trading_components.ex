defmodule EthWeb.TradingComponents do
  @moduledoc """
  Componentes compartidos por las vistas de trading (RF-6.12): el selector de familia
  **Directo · Por órdenes · Estación** (cada familia es una ruta propia y la búsqueda
  viaja de una a otra), la cabecera del tablón, el sello anti-scam, el anillo de Certeza,
  la barra de filtros acoplada a la tabla (RF-6.4) y la ficha que se despliega bajo la
  fila, con sus columnas y su pie de acciones (RF-6.5, §9.5, RF-11.2).

  Los atajos de teclado del tablón (RF-6.9) viven en `board_shortcuts/1`: un hook que
  escucha el teclado de la ventana y actúa sobre elementos marcados con
  `data-shortcut`, más el diálogo de ayuda que abre `?`.

  Implementa: RF-6.4, RF-6.5, RF-6.9, RF-6.12, RF-6.13, RF-11.2.
  """
  use EthWeb, :html

  alias Phoenix.HTML.Form
  alias Phoenix.LiveView.JS

  @doc "Selector de familia de trading (control segmentado)."
  attr :active, :atom, required: true, doc: ":direct, :orders o :station"
  attr :search, :string, default: "", doc: "búsqueda actual, se conserva al cambiar"

  def family_nav(assigns) do
    assigns = assign(assigns, :families, families(assigns.search))

    ~H"""
    <nav id="family-nav" aria-label={gettext("Familia de trading")} class="join">
      <%= for {id, label, hint, path} <- @families do %>
        <.link
          :if={path}
          id={"family-#{id}"}
          navigate={path}
          title={hint}
          aria-current={@active == id && "page"}
          class={[
            "btn join-item btn-sm font-display tracking-wide",
            if(@active == id, do: "btn-primary", else: "btn-ghost border-base-300")
          ]}
        >
          {label}
        </.link>
        <span
          :if={!path}
          id={"family-#{id}"}
          title={gettext("Próximamente")}
          class="btn btn-disabled join-item btn-sm"
        >
          {label}
        </span>
      <% end %>
    </nav>
    """
  end

  defp families(search) do
    query = if search in [nil, ""], do: %{}, else: %{"search" => search}

    [
      {:direct, gettext("Directo"),
       gettext("Comprar a órdenes de venta y vender a órdenes de compra, sin esperas"),
       ~p"/?#{query}"},
      {:orders, gettext("Por órdenes"),
       gettext("Listado y compra por orden: publicás una orden y esperás a que se ejecute"),
       ~p"/orders?#{query}"},
      {:station, gettext("Estación"),
       gettext("Station trading: comprar y vender con órdenes propias en la misma estación"),
       ~p"/station?#{query}"}
    ]
  end

  @doc "Cabecera del tablón: título, selector de familia, contadores y estado del motor."
  attr :title, :string, required: true
  attr :family, :atom, required: true
  attr :search, :string, default: ""
  attr :status_id, :string, required: true
  slot :stats
  slot :status, required: true

  def board_header(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-x-6 gap-y-3">
      <h1 class="font-display text-2xl font-semibold eth-strong sm:text-[26px]">{@title}</h1>
      <.family_nav active={@family} search={@search} />
      <div class="flex-1"></div>
      <div class="flex items-end gap-6">{render_slot(@stats)}</div>
    </div>
    <p id={@status_id} class="-mt-2 text-xs eth-faint tabular-nums">{render_slot(@status)}</p>
    """
  end

  @doc "Sello del escudo anti-scam (nada si el estado es `:ok`)."
  attr :shield, :map, required: true

  def shield_seal(assigns) do
    ~H"""
    <.seal
      :if={@shield.status == :scam}
      kind={:scam}
      title={Enum.join(@shield.reasons, " · ")}
    />
    <.seal
      :if={@shield.status in [:suspicious, :no_history]}
      kind={:suspicious}
      label={shield_label(@shield.status)}
      title={Enum.join(@shield.reasons, " · ")}
    />
    """
  end

  @doc "Texto del estado del escudo anti-scam."
  @spec shield_label(atom()) :: String.t()
  def shield_label(:scam), do: gettext("SCAM")
  def shield_label(:suspicious), do: gettext("Sospechosa")
  def shield_label(:no_history), do: gettext("Sin historial")
  def shield_label(_ok), do: gettext("ok")

  @doc "Anillo de Certeza con el porcentaje al centro y color por tramo."
  attr :value, :float, required: true
  attr :size, :integer, default: 40

  def certainty_ring(assigns) do
    ~H"""
    <.ring
      value={@value}
      size={@size}
      class={certainty_color(@value)}
      label={gettext("Certeza %{c} %", c: round(@value * 100))}
    >
      <span class="font-mono text-[10px] eth-strong">{round(@value * 100)}</span>
    </.ring>
    """
  end

  defp certainty_color(c) when c >= 0.8, do: "text-success"
  defp certainty_color(c) when c >= 0.6, do: "text-primary"
  defp certainty_color(c) when c >= 0.4, do: "text-warning"
  defp certainty_color(_c), do: "text-error"

  @doc "Título de sección de la ficha, con su \"?\" al manual."
  attr :topic, :atom, default: nil
  attr :help, :string, default: nil, doc: "texto breve del tooltip"
  slot :inner_block, required: true

  def detail_heading(assigns) do
    ~H"""
    <h3 class="eth-kicker mt-4 mb-1.5 flex items-center gap-2 text-[11px] text-primary">
      {render_slot(@inner_block)}
      <.help :if={@topic && @help} topic={@topic}>{@help}</.help>
      <.help :if={@topic && !@help} topic={@topic} />
    </h3>
    """
  end

  ## Barra de filtros (RF-6.4)

  @doc """
  Campo compacto de la barra de filtros: la etiqueta va como prefijo dentro del borde, al
  estilo de una tabla de datos. Tipos: texto, número, `select` y `toggle` (casilla).
  """
  attr :field, Phoenix.HTML.FormField, required: true
  attr :label, :string, required: true
  attr :term, :atom, default: nil, doc: "término del glosario que explica la etiqueta"
  attr :type, :string, default: "text", values: ~w(text number select toggle)
  attr :options, :list, default: []
  attr :class, :any, default: nil
  attr :rest, :global, include: ~w(placeholder min max step phx-debounce inputmode)

  def filter_field(%{type: "select"} = assigns) do
    ~H"""
    <label class={["eth-filter", @class]}>
      <span class="eth-filter-label"><.filter_label label={@label} term={@term} /></span>
      <select id={@field.id} name={@field.name} {@rest}>
        {Form.options_for_select(@options, @field.value)}
      </select>
    </label>
    """
  end

  def filter_field(%{type: "toggle"} = assigns) do
    assigns =
      assign(
        assigns,
        :checked,
        Form.normalize_value("checkbox", assigns.field.value)
      )

    ~H"""
    <label class={["eth-filter eth-filter-toggle", @class]}>
      <input type="hidden" name={@field.name} value="false" />
      <span class="eth-filter-label gap-2 border-r-0">
        <input
          type="checkbox"
          id={@field.id}
          name={@field.name}
          value="true"
          checked={@checked}
          class="checkbox checkbox-primary checkbox-xs"
        />
        <.filter_label label={@label} term={@term} />
      </span>
    </label>
    """
  end

  def filter_field(assigns) do
    ~H"""
    <label class={["eth-filter", @class]}>
      <span class="eth-filter-label"><.filter_label label={@label} term={@term} /></span>
      <input
        type={@type}
        id={@field.id}
        name={@field.name}
        value={Form.normalize_value(@type, @field.value)}
        {@rest}
      />
    </label>
    """
  end

  attr :label, :string, required: true
  attr :term, :atom, default: nil

  defp filter_label(%{term: nil} = assigns), do: ~H"{@label}"

  defp filter_label(assigns) do
    ~H"""
    <.term name={@term} align="start">{@label}</.term>
    """
  end

  @doc "Buscador de la barra de filtros, con ícono."
  attr :field, Phoenix.HTML.FormField, required: true
  attr :placeholder, :string, required: true
  attr :class, :any, default: nil

  def filter_search(assigns) do
    ~H"""
    <label class={["eth-filter", @class]}>
      <span class="eth-filter-label border-r-0 pr-0">
        <.icon name="hero-magnifying-glass" class="size-4" />
      </span>
      <input
        type="search"
        id={@field.id}
        name={@field.name}
        value={@field.value}
        placeholder={@placeholder}
        phx-debounce="300"
        aria-label={@placeholder}
        data-shortcut="search"
      />
    </label>
    """
  end

  ## Atajos de teclado (RF-6.9)

  @doc """
  Atajos del tablón y su diálogo de ayuda. Actúan sobre la página, nunca mientras se
  escribe en un campo: `/` buscar, `j`/`k` recorrer filas, `Enter` abrir o cerrar la
  ficha, `c` copiar (Multibuy o precio), `w` fijar ruta, `f` congelar, `?` ayuda y `Esc`
  cerrar. Las acciones in-game siguen necesitando la tecla explícita del piloto.
  """
  attr :id, :string, default: "board-shortcuts"

  def board_shortcuts(assigns) do
    ~H"""
    <dialog
      id={@id}
      phx-hook=".Shortcuts"
      phx-update="ignore"
      aria-labelledby={"#{@id}-title"}
      class="eth-raised eth-chamfer m-auto w-[min(26rem,calc(100vw-2rem))] border border-base-300 bg-base-100 p-0 text-base-content backdrop:bg-black/50"
    >
      <div class="flex items-center justify-between border-b border-base-300 px-4 py-2.5">
        <h2 id={"#{@id}-title"} class="eth-kicker">{gettext("Atajos de teclado")}</h2>
        <form method="dialog">
          <button class="btn btn-ghost btn-xs" aria-label={gettext("Cerrar")}>
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </form>
      </div>
      <dl class="grid grid-cols-[auto_1fr] items-center gap-x-4 gap-y-2 px-4 py-3 text-sm">
        <dt><kbd class="kbd kbd-sm">/</kbd></dt>
        <dd>{gettext("Buscar")}</dd>
        <dt><kbd class="kbd kbd-sm">j</kbd> <kbd class="kbd kbd-sm">k</kbd></dt>
        <dd>{gettext("Bajar o subir por los contratos")}</dd>
        <dt><kbd class="kbd kbd-sm">Enter</kbd></dt>
        <dd>{gettext("Abrir o cerrar la ficha del contrato")}</dd>
        <dt><kbd class="kbd kbd-sm">c</kbd></dt>
        <dd>{gettext("Copiar el Multibuy o el precio de la ficha abierta")}</dd>
        <dt><kbd class="kbd kbd-sm">w</kbd></dt>
        <dd>{gettext("Fijar la ruta en el juego")}</dd>
        <dt><kbd class="kbd kbd-sm">f</kbd></dt>
        <dd>{gettext("Congelar o reanudar el tablón")}</dd>
        <dt><kbd class="kbd kbd-sm">Esc</kbd></dt>
        <dd>{gettext("Cerrar la ficha o este diálogo")}</dd>
        <dt><kbd class="kbd kbd-sm">?</kbd></dt>
        <dd>{gettext("Mostrar esta ayuda")}</dd>
      </dl>
      <p class="border-t border-base-300 px-4 py-2 text-xs eth-faint">
        {gettext("Los atajos no actúan mientras escribís en un campo.")}
      </p>
    </dialog>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".Shortcuts">
      const TYPING = "input, textarea, select, [contenteditable=true]"

      export default {
        mounted() {
          this.onKey = (event) => this.handle(event)
          window.addEventListener("keydown", this.onKey)
        },
        destroyed() {
          window.removeEventListener("keydown", this.onKey)
        },
        rows() {
          return Array.from(document.querySelectorAll("[data-head]"))
        },
        press(name) {
          const el = document.querySelector(`[data-shortcut="${name}"]:not([disabled])`)
          if (el) el.click()
          return !!el
        },
        move(step) {
          const rows = this.rows()
          if (rows.length === 0) return
          const current = rows.indexOf(document.activeElement)
          const next = current === -1 ? 0 : Math.min(Math.max(current + step, 0), rows.length - 1)
          rows[next].focus()
          rows[next].scrollIntoView({block: "nearest"})
        },
        handle(event) {
          if (event.ctrlKey || event.metaKey || event.altKey) return
          if (event.target.closest && event.target.closest(TYPING)) return
          if (this.el.open) return

          switch (event.key) {
            case "/": {
              const search = document.querySelector("[data-shortcut=search]")
              if (search) { event.preventDefault(); search.focus(); search.select() }
              break
            }
            case "j": event.preventDefault(); this.move(1); break
            case "k": event.preventDefault(); this.move(-1); break
            case "Enter":
            case " ": {
              const row = document.activeElement
              if (row && row.matches("[data-head]")) { event.preventDefault(); row.click() }
              break
            }
            case "c": this.press("copy"); break
            case "w": this.press("route"); break
            case "f": this.press("freeze"); break
            case "?": event.preventDefault(); this.el.showModal(); break
          }
        }
      }
    </script>
    """
  end

  ## Ficha bajo la fila (RF-6.5)

  @doc """
  Contenedor de la ficha que se despliega bajo la fila: se desenrolla al abrir, se
  desvanece al cerrar y se desplaza a la vista si quedó fuera de la pantalla.
  """
  attr :id, :string, required: true
  attr :label, :string, required: true
  slot :inner_block, required: true
  slot :footer

  def row_detail(assigns) do
    ~H"""
    <section
      id={@id}
      aria-label={@label}
      phx-hook=".Reveal"
      phx-remove={
        JS.transition({"transition-opacity duration-150 ease-in", "opacity-100", "opacity-0"},
          time: 150
        )
      }
      class="eth-unfold cursor-default border-t border-primary/30 bg-base-200/70 px-4 pt-4 pb-3"
    >
      <div class="grid gap-x-6 gap-y-5 md:grid-cols-2 xl:grid-cols-4">
        {render_slot(@inner_block)}
      </div>
      <div
        :if={@footer != []}
        class="mt-4 flex flex-wrap items-center gap-2 border-t border-base-300 pt-3"
      >
        {render_slot(@footer)}
      </div>
    </section>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".Reveal">
      export default {
        mounted() {
          const rect = this.el.getBoundingClientRect()
          if (rect.bottom > window.innerHeight || rect.top < 0) {
            const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches
            this.el.scrollIntoView({block: "nearest", behavior: reduce ? "auto" : "smooth"})
          }
        }
      }
    </script>
    """
  end

  @doc "Columna de la ficha: título en versalitas con su \"?\" y contenido."
  attr :title, :string, required: true
  attr :topic, :atom, default: nil
  attr :help, :string, default: nil
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def detail_col(assigns) do
    ~H"""
    <div class={["min-w-0", @class]}>
      <h3 class="eth-kicker mb-2 flex items-center gap-2 text-[11px] text-primary">
        {@title}
        <.help :if={@topic && @help} topic={@topic} title={@title}>{@help}</.help>
        <.help :if={@topic && !@help} topic={@topic} title={@title} />
      </h3>
      {render_slot(@inner_block)}
    </div>
    """
  end
end
