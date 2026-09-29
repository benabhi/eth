defmodule EthWeb.TradingComponents do
  @moduledoc """
  Componentes compartidos por las vistas de trading (RF-6.12): el selector de familia
  **Directo · Por órdenes · Estación**. Cada familia es una ruta propia (la URL la
  conserva) y la búsqueda viaja de una a otra.

  Implementa: RF-6.12.
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
          class={["btn join-item btn-sm", if(@active == id, do: "btn-primary", else: "btn-ghost")]}
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
end
