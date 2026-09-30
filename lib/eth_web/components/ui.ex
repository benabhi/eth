defmodule EthWeb.UI do
  @moduledoc """
  Componentes compartidos del diseño "puente de mando" (ERS §9.9, §9.10). Un único
  juego de piezas para toda la aplicación, en modo noche y modo día (RNF-5.1): lo que
  avisa, flota, espera o se explica se ve igual en todas las pantallas.

  - Estructura: `panel/1`, `stat/1`, `empty_state/1`.
  - Explicabilidad (RNF-5.14, RF-11.2): `help/1` ("?" en círculo con tooltip y enlace
    al manual) y `tip/1` (cualquier cifra con su definición y fórmula).
  - Tablón (RF-6.13): `rank_badge/1`, `seal/1`, `danger_meter/1`.
  - Instrumentos (§9.10): `ring/1`, `double_ring/1`, `arc/1`, `pulse/1`, `steps/1`.
  - Carga (RNF-5.15): `spinner/1`, `skeleton/1`.

  Implementa: RNF-5.1, RNF-5.9–RNF-5.15, RF-6.13, RF-11.2.
  """
  use Phoenix.Component
  use Gettext, backend: EthWeb.Gettext

  alias Eth.Engine.Grade
  alias EthWeb.{Docs, Glossary}

  ## Estructura

  @doc "Panel con chaflán, cabecera en versalitas, ayuda opcional y acciones."
  attr :id, :string, default: nil
  attr :title, :string, default: nil
  attr :help, :atom, default: nil, doc: "tema del manual para el \"?\" de la cabecera"
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true
  slot :actions
  slot :help_body

  def panel(assigns) do
    ~H"""
    <section
      id={@id}
      class={["eth-chamfer border border-base-300 bg-base-100", @class]}
      {@rest}
    >
      <header
        :if={@title || @actions != []}
        class="flex items-center justify-between gap-3 border-b border-base-300 px-4 py-2.5"
      >
        <h2 :if={@title} class="eth-kicker flex items-center gap-2">
          {@title}
          <.help :if={@help && @help_body != []} topic={@help} title={@title}>
            {render_slot(@help_body)}
          </.help>
          <.help :if={@help && @help_body == []} topic={@help} title={@title} />
        </h2>
        <div :if={@actions != []} class="flex items-center gap-2">{render_slot(@actions)}</div>
      </header>
      <div class="p-4">{render_slot(@inner_block)}</div>
    </section>
    """
  end

  @doc """
  Pestañas con URL propia (RF-8.10): cada una es un `patch`, así el navegador conserva la
  pestaña al recargar y el historial funciona. El contador opcional marca lo que requiere
  atención.
  """
  attr :id, :string, required: true
  attr :active, :string, required: true
  attr :label, :string, required: true, doc: "nombre accesible del grupo"

  attr :tabs, :list,
    required: true,
    doc: "[{clave, etiqueta, ruta}] o [{clave, etiqueta, ruta, contador}]"

  def tabs(assigns) do
    ~H"""
    <nav
      id={@id}
      aria-label={@label}
      class="-mx-4 flex gap-1 overflow-x-auto overflow-y-hidden border-b border-base-300 px-4 sm:mx-0 sm:px-0"
    >
      <.link
        :for={tab <- @tabs}
        id={"#{@id}-#{elem(tab, 0)}"}
        patch={elem(tab, 2)}
        aria-current={@active == elem(tab, 0) && "page"}
        class={[
          "-mb-px flex shrink-0 items-center gap-2 border-b-2 px-3 py-2 font-display text-xs font-semibold uppercase tracking-[0.14em] transition-colors",
          if(@active == elem(tab, 0),
            do: "border-primary text-primary",
            else: "border-transparent eth-muted hover:text-base-content"
          )
        ]}
      >
        {elem(tab, 1)}
        <span
          :if={tuple_size(tab) > 3 and elem(tab, 3) > 0}
          class="bg-warning px-1.5 font-mono text-[10px] text-warning-content"
        >
          {elem(tab, 3)}
        </span>
      </.link>
    </nav>
    """
  end

  @doc "Cifra destacada con su etiqueta."
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :class, :any, default: nil
  attr :value_class, :any, default: nil
  attr :rest, :global

  def stat(assigns) do
    ~H"""
    <div class={["flex flex-col", @class]} {@rest}>
      <span class={["font-mono text-lg tabular-nums eth-strong", @value_class]}>{@value}</span>
      <span class="text-xs eth-faint">{@label}</span>
    </div>
    """
  end

  @doc "Estado vacío con ícono, explicación y acción."
  attr :id, :string, default: nil
  attr :title, :string, required: true
  attr :class, :any, default: nil
  slot :inner_block
  slot :actions

  def empty_state(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "flex flex-col items-center gap-2 border border-dashed border-base-300 px-6 py-8 text-center",
        @class
      ]}
    >
      <svg width="36" height="36" viewBox="0 0 40 40" aria-hidden="true" class="text-primary">
        <circle cx="18" cy="18" r="12" fill="none" stroke="currentColor" stroke-width="1.5" />
        <path d="M27 27 L36 36" stroke="currentColor" stroke-width="1.5" />
      </svg>
      <span class="font-semibold eth-strong">{@title}</span>
      <span :if={@inner_block != []} class="max-w-md text-sm eth-muted">
        {render_slot(@inner_block)}
      </span>
      <div :if={@actions != []} class="mt-1 flex gap-2">{render_slot(@actions)}</div>
    </div>
    """
  end

  @doc """
  Ícono de un tipo del juego (servidor de imágenes de EVE) con respaldo: algunos tipos,
  como muchos SKINs, no tienen ícono (404) y en su lugar se muestra una caja genérica en el
  mismo recuadro. El hook `.TypeIcon` detecta la falla aunque haya ocurrido antes de que
  cargue el JS (el CSP no permite `onerror` inline).
  """
  attr :id, :string, required: true
  attr :type_id, :integer, required: true
  attr :size, :integer, default: 24, doc: "lado en px del recuadro"
  attr :class, :any, default: nil

  def type_icon(assigns) do
    assigns = assign(assigns, :src_size, if(assigns.size > 32, do: 64, else: 32))

    ~H"""
    <span
      id={@id}
      phx-hook=".TypeIcon"
      phx-update="ignore"
      data-type-id={@type_id}
      class={["relative inline-flex shrink-0 items-center justify-center bg-base-300", @class]}
      style={"width: #{@size}px; height: #{@size}px"}
    >
      <img
        src={"https://images.evetech.net/types/#{@type_id}/icon?size=#{@src_size}"}
        alt=""
        width={@size}
        height={@size}
        loading="lazy"
      />
      <svg
        viewBox="0 0 24 24"
        aria-hidden="true"
        class="text-base-content/40"
        style={"display: none; width: #{round(@size * 0.7)}px; height: #{round(@size * 0.7)}px"}
      >
        <path
          d="M12 3 20 7.5v9L12 21l-8-4.5v-9L12 3Zm0 0v18M4 7.5l8 4.5 8-4.5"
          fill="none"
          stroke="currentColor"
          stroke-width="1.5"
          stroke-linejoin="round"
        />
      </svg>
    </span>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".TypeIcon">
      export default {
        // El contenido va con phx-update="ignore": LiveView no revierte el respaldo.
        mounted() {
          const img = this.el.querySelector("img")
          const fallback = this.el.querySelector("svg")
          const fail = () => {
            img.style.display = "none"
            fallback.style.display = "block"
          }
          if (img.complete && img.naturalWidth === 0) fail()
          else img.addEventListener("error", fail, { once: true })
        }
      }
    </script>
    """
  end

  ## Explicabilidad

  @doc """
  Ícono de ayuda "?" en círculo: al pasar el cursor, con el foco o con un toque abre la
  explicación y enlaza a la sección del manual del tema (RF-11.2, RNF-5.14).
  """
  attr :topic, :atom, required: true
  attr :title, :string, default: nil
  attr :align, :string, default: "center", values: ~w(center start end)
  slot :inner_block

  def help(assigns) do
    assigns = assign(assigns, :href, Docs.href(assigns.topic))

    ~H"""
    <span class="eth-tip">
      <button
        type="button"
        class="eth-help"
        aria-label={gettext("Ayuda: %{title}", title: @title || gettext("qué significa"))}
      >
        ?
      </button>
      <span role="tooltip" class={["eth-tip-body eth-raised", align_class(@align)]}>
        <span :if={@title} class="eth-kicker mb-1 block text-primary">{@title}</span>
        <%!-- Sin texto propio, el resumen del tema: ningún "?" queda solo con el enlace. --%>
        <span :if={@inner_block != []} class="block" data-tip-text>{render_slot(@inner_block)}</span>
        <span :if={@inner_block == []} class="block" data-tip-text>{Docs.summary(@topic)}</span>
        <.link navigate={@href} class="mt-2 block text-xs link link-primary">
          {gettext("Leer en la documentación →")}
        </.link>
      </span>
    </span>
    """
  end

  @doc """
  Cifra con tooltip: definición, fórmula con los valores reales y enlace al manual
  (RNF-5.14, RF-11.3). El disparador lleva un subrayado punteado y recibe foco.
  """
  attr :title, :string, required: true
  attr :topic, :atom, default: nil
  attr :align, :string, default: "center", values: ~w(center start end)
  attr :class, :any, default: nil
  slot :inner_block, required: true
  slot :body
  slot :formula

  def tip(assigns) do
    ~H"""
    <span class={["eth-tip", @class]}>
      <span tabindex="0" class="cursor-help border-b border-dashed border-primary/60">
        {render_slot(@inner_block)}
      </span>
      <span role="tooltip" class={["eth-tip-body eth-raised", align_class(@align)]}>
        <span class="eth-kicker mb-1 block text-primary">{@title}</span>
        <span :if={@body != []} class="block" data-tip-text>{render_slot(@body)}</span>
        <span :if={@formula != []} class="eth-formula mt-2 block" data-tip-text>{render_slot(@formula)}</span>
        <.link :if={@topic} navigate={Docs.href(@topic)} class="mt-2 block text-xs link link-primary">
          {gettext("Leer en la documentación →")}
        </.link>
      </span>
    </span>
    """
  end

  @doc """
  Sigla o término del juego explicado donde aparece (RNF-5.14): subrayado punteado
  tenue y, al pasar el cursor o con el foco, la definición del glosario
  (`EthWeb.Glossary`) con el enlace a la documentación. Sin JS.

  Se usa en la **primera** aparición de un término en cada vista (etiquetas y títulos),
  no en cada repetición: el objetivo es que nada quede sin explicar sin llenar la
  pantalla de ayudas.
  """
  attr :name, :atom, required: true, doc: "clave del término en `EthWeb.Glossary`"
  attr :align, :string, default: "center", values: ~w(center start end)
  attr :class, :any, default: nil
  slot :inner_block, doc: "texto visible; por defecto, el nombre del término"

  def term(assigns) do
    entry = Glossary.fetch!(assigns.name)

    assigns =
      assign(assigns,
        entry: entry,
        href: if(entry.topic, do: Docs.href(entry.topic), else: Glossary.href(entry.key))
      )

    ~H"""
    <span class={["eth-tip", @class]}>
      <span tabindex="0" class="cursor-help border-b border-dotted border-current/40">
        {if @inner_block != [], do: render_slot(@inner_block), else: @entry.term}
      </span>
      <span role="tooltip" class={["eth-tip-body eth-raised", align_class(@align)]}>
        <span class="eth-kicker mb-1 block text-primary">{@entry.term}</span>
        <span class="block normal-case tracking-normal" data-tip-text>{@entry.definition}</span>
        <.link navigate={@href} class="mt-2 block text-xs link link-primary">
          {gettext("Leer en la documentación →")}
        </.link>
      </span>
    </span>
    """
  end

  defp align_class("start"), do: "eth-tip-start"
  defp align_class("end"), do: "eth-tip-end"
  defp align_class(_center), do: nil

  ## Tablón de caza

  @doc "Rango del contrato (S, A, B, C, D) a partir del TVS o de la letra."
  attr :tvs, :integer, default: nil
  attr :rank, :string, default: nil
  attr :size, :string, default: "md", values: ~w(sm md lg)
  attr :rest, :global

  def rank_badge(assigns) do
    assigns = assign_new(assigns, :letter, fn -> assigns.rank || Grade.rank(assigns.tvs || 0) end)

    ~H"""
    <span
      class={[
        "eth-chamfer-xs inline-flex shrink-0 items-center justify-center border font-display font-bold",
        rank_size(@size),
        rank_color(@letter)
      ]}
      title={gettext("Rango %{rank}", rank: @letter)}
      {@rest}
    >
      {@letter}
    </span>
    """
  end

  defp rank_size("sm"), do: "size-7 text-sm"
  defp rank_size("lg"), do: "size-12 text-2xl"
  defp rank_size(_md), do: "size-10 text-lg"

  defp rank_color("S"), do: "border-accent text-accent bg-accent/10"
  defp rank_color("A"), do: "border-primary text-primary bg-primary/10"
  defp rank_color("B"), do: "border-success text-success bg-success/10"
  defp rank_color("C"), do: "border-base-content/40 text-base-content/70"
  defp rank_color(_d), do: "border-base-content/25 text-base-content/45"

  @doc "Sello de estado del contrato."
  attr :kind, :atom,
    required: true,
    values: ~w(new improved risk scam expired order structure range illiquid suspicious)a

  attr :label, :string, default: nil
  attr :rest, :global

  def seal(assigns) do
    ~H"""
    <span
      class={[
        "inline-flex items-center border px-1.5 py-px font-display text-[10px] font-semibold uppercase tracking-[0.14em]",
        seal_color(@kind)
      ]}
      {@rest}
    >
      {@label || seal_label(@kind)}
    </span>
    """
  end

  defp seal_label(:new), do: gettext("Nuevo")
  defp seal_label(:improved), do: gettext("Mejoró")
  defp seal_label(:risk), do: gettext("En riesgo")
  defp seal_label(:scam), do: gettext("Scam · bloqueado")
  defp seal_label(:expired), do: gettext("Expirado")
  defp seal_label(:order), do: gettext("Orden")
  defp seal_label(:structure), do: gettext("Estructura")
  defp seal_label(:range), do: gettext("Venta por rango")
  defp seal_label(:illiquid), do: gettext("Ilíquido")
  defp seal_label(:suspicious), do: gettext("Sospechosa")

  defp seal_color(:new), do: "border-primary/70 text-primary"
  defp seal_color(:improved), do: "border-success/70 text-success"

  defp seal_color(k) when k in [:risk, :illiquid, :suspicious],
    do: "border-warning/70 text-warning"

  defp seal_color(:scam), do: "border-error text-error bg-error/10"
  defp seal_color(:order), do: "border-secondary/70 text-secondary"
  defp seal_color(:range), do: "border-info/70 text-info"
  defp seal_color(_k), do: "border-base-content/30 text-base-content/60"

  @doc "Barra de peligro de ruta en cuatro tramos, con su texto (color nunca solo)."
  attr :level, :atom, required: true, values: [:low, :moderate, :high, :extreme]
  attr :label, :string, default: nil
  attr :rest, :global

  def danger_meter(assigns) do
    assigns = assign(assigns, :step, Grade.danger_step(assigns.level))

    ~H"""
    <div class="flex flex-col gap-1" {@rest}>
      <div class="flex gap-0.5" aria-hidden="true">
        <span
          :for={i <- 1..4}
          class={["h-1.5 flex-1", if(i <= @step, do: danger_color(@level), else: "bg-base-300")]}
        ></span>
      </div>
      <span class="text-xs eth-muted">{@label || danger_label(@level)}</span>
    </div>
    """
  end

  @doc false
  @spec danger_label(Grade.danger()) :: String.t()
  def danger_label(:low), do: gettext("Bajo")
  def danger_label(:moderate), do: gettext("Moderado")
  def danger_label(:high), do: gettext("Alto")
  def danger_label(:extreme), do: gettext("Extremo")

  defp danger_color(:low), do: "bg-success"
  defp danger_color(:moderate), do: "bg-warning"
  defp danger_color(:high), do: "bg-accent"
  defp danger_color(:extreme), do: "bg-error"

  ## Instrumentos (§9.10)

  @doc "Anillo de progreso (0–1) con contenido centrado."
  attr :value, :float, required: true
  attr :size, :integer, default: 44
  attr :stroke, :integer, default: 4
  attr :class, :any, default: "text-primary", doc: "color del trazo (currentColor)"
  attr :label, :string, default: nil, doc: "texto accesible"
  slot :inner_block

  def ring(assigns) do
    assigns = ring_geometry(assigns, assigns.size, assigns.stroke, assigns.value)

    ~H"""
    <div
      class="relative inline-flex shrink-0 items-center justify-center"
      style={"width: #{@size}px; height: #{@size}px"}
      role="img"
      aria-label={@label}
    >
      <svg width={@size} height={@size} viewBox={"0 0 #{@size} #{@size}"} aria-hidden="true">
        <circle
          cx={@c}
          cy={@c}
          r={@r}
          fill="none"
          class="stroke-base-300"
          stroke-width={@stroke}
        />
        <circle
          cx={@c}
          cy={@c}
          r={@r}
          fill="none"
          stroke="currentColor"
          class={@class}
          stroke-width={@stroke}
          stroke-linecap="round"
          stroke-dasharray={@dash}
          transform={"rotate(-90 #{@c} #{@c})"}
        />
      </svg>
      <span class="absolute inset-0 flex flex-col items-center justify-center">
        {render_slot(@inner_block)}
      </span>
    </div>
    """
  end

  @doc """
  Anillo doble de un poller: el exterior cuenta el tiempo hasta `Expires`, el interior
  las páginas del ciclo (§9.10).
  """
  attr :outer, :float, required: true
  attr :inner, :float, required: true
  attr :size, :integer, default: 112
  attr :outer_class, :any, default: "text-primary"
  attr :inner_class, :any, default: "text-success"
  attr :label, :string, default: nil
  slot :inner_block

  def double_ring(assigns) do
    o = ring_geometry(%{}, assigns.size, 6, assigns.outer)
    i = ring_geometry(%{}, assigns.size - 22, 4, assigns.inner)

    assigns =
      assigns
      |> assign(:o, o)
      |> assign(:i, i)
      |> assign(:offset, 11)

    ~H"""
    <div
      class="relative inline-flex shrink-0 items-center justify-center"
      style={"width: #{@size}px; height: #{@size}px"}
      role="img"
      aria-label={@label}
    >
      <svg width={@size} height={@size} viewBox={"0 0 #{@size} #{@size}"} aria-hidden="true">
        <circle cx={@o.c} cy={@o.c} r={@o.r} fill="none" class="stroke-base-300" stroke-width="6" />
        <circle
          cx={@o.c}
          cy={@o.c}
          r={@o.r}
          fill="none"
          stroke="currentColor"
          class={@outer_class}
          stroke-width="6"
          stroke-linecap="round"
          stroke-dasharray={@o.dash}
          transform={"rotate(-90 #{@o.c} #{@o.c})"}
        />
        <g transform={"translate(#{@offset} #{@offset})"}>
          <circle cx={@i.c} cy={@i.c} r={@i.r} fill="none" class="stroke-base-300" stroke-width="4" />
          <circle
            cx={@i.c}
            cy={@i.c}
            r={@i.r}
            fill="none"
            stroke="currentColor"
            class={@inner_class}
            stroke-width="4"
            stroke-dasharray={@i.dash}
            transform={"rotate(-90 #{@i.c} #{@i.c})"}
          />
        </g>
      </svg>
      <span class="absolute inset-0 flex flex-col items-center justify-center gap-0.5">
        {render_slot(@inner_block)}
      </span>
    </div>
    """
  end

  defp ring_geometry(assigns, size, stroke, value) do
    r = (size - stroke) / 2
    circumference = 2 * :math.pi() * r
    filled = circumference * min(max(value, 0.0), 1.0)

    Map.merge(assigns, %{
      c: size / 2,
      r: Float.round(r, 2),
      dash: "#{Float.round(filled, 2)} #{Float.round(circumference, 2)}"
    })
  end

  @doc "Arco (medio anillo) para presupuestos: 0–1 usado."
  attr :value, :float, required: true
  attr :width, :integer, default: 140
  attr :class, :any, default: "text-primary"
  attr :label, :string, default: nil
  slot :inner_block

  def arc(assigns) do
    w = assigns.width
    r = (w - 12) / 2
    length = :math.pi() * r
    filled = length * min(max(assigns.value, 0.0), 1.0)

    assigns =
      assign(assigns,
        h: round(r + 8),
        path:
          "M 6 #{Float.round(r + 6, 2)} A #{Float.round(r, 2)} #{Float.round(r, 2)} 0 0 1 #{w - 6} #{Float.round(r + 6, 2)}",
        dash: "#{Float.round(filled, 2)} #{Float.round(length, 2)}"
      )

    ~H"""
    <div class="relative inline-flex flex-col items-center" role="img" aria-label={@label}>
      <svg width={@width} height={@h} viewBox={"0 0 #{@width} #{@h}"} aria-hidden="true">
        <path d={@path} fill="none" class="stroke-base-300" stroke-width="10" />
        <path
          d={@path}
          fill="none"
          stroke="currentColor"
          class={@class}
          stroke-width="10"
          stroke-dasharray={@dash}
        />
      </svg>
      <span class="-mt-7 flex flex-col items-center">{render_slot(@inner_block)}</span>
    </div>
    """
  end

  @doc "Pulso del feed del radar: late mientras esté en vivo."
  attr :live, :boolean, default: true
  attr :size, :integer, default: 56

  def pulse(assigns) do
    ~H"""
    <svg
      width={@size}
      height={@size}
      viewBox="0 0 64 64"
      aria-hidden="true"
      class={if(@live, do: "text-success", else: "text-warning")}
    >
      <circle
        :if={@live}
        class="eth-pulse-ring"
        cx="32"
        cy="32"
        r="8"
        fill="none"
        stroke="currentColor"
        stroke-width="1.5"
      />
      <circle
        cx="32"
        cy="32"
        r="19"
        fill="none"
        stroke="currentColor"
        stroke-width="1"
        opacity="0.35"
      />
      <circle cx="32" cy="32" r="8" fill="currentColor" />
    </svg>
    """
  end

  @doc "Secuencia de pasos (descarga → proceso → grafo → listo)."
  attr :steps, :list, required: true, doc: "[{etiqueta, :done | :current | :pending}]"

  def steps(assigns) do
    ~H"""
    <ol class="flex items-start gap-1.5">
      <li :for={{label, state} <- @steps} class="flex flex-1 flex-col gap-1">
        <span class={[
          "h-1",
          case state do
            :done -> "bg-success"
            :current -> "bg-primary"
            _ -> "bg-base-300"
          end
        ]}></span>
        <span class={["text-[11px]", if(state == :current, do: "eth-strong", else: "eth-muted")]}>
          {label}
        </span>
      </li>
    </ol>
    """
  end

  ## Carga (RNF-5.15)

  @doc "Spinner con el texto de lo que se está haciendo."
  attr :size, :integer, default: 22
  attr :label, :string, default: nil
  attr :hint, :string, default: nil
  attr :class, :any, default: "text-primary"
  attr :rest, :global

  def spinner(assigns) do
    ~H"""
    <span class="inline-flex items-center gap-3" role="status" {@rest}>
      <svg
        class={["eth-spin", @class]}
        width={@size}
        height={@size}
        viewBox="0 0 22 22"
        aria-hidden="true"
      >
        <circle cx="11" cy="11" r="9" fill="none" class="stroke-base-300" stroke-width="2.5" />
        <path d="M11 2 A9 9 0 0 1 20 11" fill="none" stroke="currentColor" stroke-width="2.5" />
      </svg>
      <span :if={@label} class="flex flex-col">
        <span class="text-sm eth-strong">{@label}</span>
        <span :if={@hint} class="text-xs eth-faint">{@hint}</span>
      </span>
      <span :if={!@label} class="sr-only">{gettext("Cargando")}</span>
    </span>
    """
  end

  @doc "Skeleton de filas: la forma del contenido mientras carga."
  attr :rows, :integer, default: 4
  attr :id, :string, default: nil

  def skeleton(assigns) do
    ~H"""
    <div id={@id} class="flex flex-col gap-2" aria-hidden="true">
      <div :for={i <- 1..@rows} class="flex items-center gap-3 border border-base-300/60 px-3 py-2.5">
        <div class="eth-skel size-9"></div>
        <div class="flex flex-1 flex-col gap-1.5">
          <div class="eth-skel h-2.5" style={"width: #{50 + rem(i * 17, 30)}%"}></div>
          <div class="eth-skel h-2" style={"width: #{30 + rem(i * 23, 25)}%"}></div>
        </div>
        <div class="eth-skel h-3.5 w-16"></div>
      </div>
    </div>
    """
  end
end
