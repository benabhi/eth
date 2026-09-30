defmodule EthWeb.TradingComponents do
  @moduledoc """
  Componentes compartidos por las vistas de trading (RF-6.12): el selector de familia
  **Directo · Por órdenes · Estación** (cada familia es una ruta propia y la búsqueda
  viaja de una a otra), la cabecera del tablón, el sello anti-scam, el anillo de Certeza
  y los títulos de sección de la ficha con su "?" (§9.5, RF-11.2).

  Implementa: RF-6.12, RF-6.13, RF-11.2.
  """
  use EthWeb, :html

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
      <.help :if={@topic} topic={@topic}>{@help}</.help>
    </h3>
    """
  end

  @doc "Estado vacío de la ficha cuando no hay nada seleccionado."
  attr :id, :string, required: true
  attr :topic, :atom, required: true
  attr :link, :string, required: true
  slot :inner_block, required: true

  def detail_placeholder(assigns) do
    ~H"""
    <h2 id={@id} class="eth-kicker">{gettext("Ficha del contrato")}</h2>
    <p class="mt-2 text-sm eth-muted">{render_slot(@inner_block)}</p>
    <p class="mt-3 text-xs">
      <.link href={EthWeb.Docs.href(@topic)} class="link link-primary">{@link}</.link>
    </p>
    """
  end
end
