defmodule EthWeb.DocsPages do
  @moduledoc """
  Páginas del manual integrado (RF-11.1): plantillas HEEx compiladas en la aplicación
  (`docs_pages/*.html.heex`), una por página de `EthWeb.Docs.pages/0`.

  Se escriben en HEEx y no en Markdown (D-21) para mostrar los **valores vigentes** de
  las reglas del juego (`Eth.GameRules`, RF-11.4) y reutilizar los componentes de la
  interfaz (fórmulas, rangos, sellos).

  Implementa: RF-11.1, RF-11.3, RF-11.4.
  """
  use EthWeb, :html

  alias Eth.GameRules
  alias EthWeb.Docs
  alias Phoenix.HTML.Safe

  embed_templates "docs_pages/*"

  @doc "Renderiza una página por su slug (`nil` si no existe)."
  @spec render_page(String.t(), map()) :: Phoenix.LiveView.Rendered.t() | nil
  for {slug, _title, _group} <- Docs.pages() do
    # Nombre de función derivado en compilación de una lista fija (no de datos externos).
    fun = slug |> String.replace("-", "_") |> String.to_atom()
    def render_page(unquote(slug), assigns), do: unquote(fun)(assigns)
  end

  def render_page(_slug, _assigns), do: nil

  @doc "HTML de una página como texto (búsqueda y test de anclas)."
  @spec page_html(String.t()) :: String.t()
  def page_html(slug) do
    case render_page(slug, %{}) do
      nil -> ""
      rendered -> rendered |> Safe.to_iodata() |> IO.iodata_to_binary()
    end
  end

  @doc "Encabezados de una página: `[{id, texto}]` (para \"En esta página\" y el test)."
  @spec headings(String.t()) :: [{String.t(), String.t()}]
  def headings(slug) do
    ~r/<h2[^>]*id="([^"]+)"[^>]*>(.*?)<\/h2>/s
    |> Regex.scan(page_html(slug))
    |> Enum.map(fn [_, id, text] -> {id, text |> strip_tags() |> String.trim()} end)
  end

  @doc "Texto plano de una página (búsqueda)."
  @spec plain_text(String.t()) :: String.t()
  def plain_text(slug), do: slug |> page_html() |> strip_tags()

  defp strip_tags(html),
    do: html |> String.replace(~r/<[^>]+>/, " ") |> String.replace(~r/\s+/, " ")

  ## Componentes de las páginas

  @doc "Encabezado de sección con ancla enlazable."
  attr :id, :string, required: true
  slot :inner_block, required: true

  def section_title(assigns) do
    ~H"""
    <h2 id={@id} class="group mt-10 scroll-mt-24 font-display text-2xl font-semibold eth-strong">
      <a href={"##{@id}"} class="no-underline">
        {render_slot(@inner_block)}
        <span class="ml-1 text-primary opacity-0 transition-opacity group-hover:opacity-100">#</span>
      </a>
    </h2>
    """
  end

  @doc "Caja de fórmula."
  attr :title, :string, default: nil
  slot :inner_block, required: true

  def formula(assigns) do
    ~H"""
    <div class="eth-chamfer my-5 border border-base-300 bg-base-100 px-5 py-4">
      <div :if={@title} class="eth-kicker mb-2 text-primary">{@title}</div>
      <div class="font-mono text-[15px] leading-8 eth-strong">{render_slot(@inner_block)}</div>
    </div>
    """
  end

  @doc "Aviso destacado."
  attr :kind, :atom, default: :tip, values: [:tip, :warning]
  slot :inner_block, required: true

  def callout(assigns) do
    ~H"""
    <div class={[
      "my-5 flex gap-3 border px-4 py-3 text-sm leading-relaxed",
      if(@kind == :warning,
        do: "border-warning/50 bg-warning/10",
        else: "border-primary/40 bg-primary/5"
      )
    ]}>
      <span class={[
        "font-display font-bold",
        if(@kind == :warning, do: "text-warning", else: "text-primary")
      ]}>
        {if @kind == :warning, do: "!", else: "i"}
      </span>
      <div>{render_slot(@inner_block)}</div>
    </div>
    """
  end

  @doc "Enlace a otra página o sección del manual por tema."
  attr :topic, :atom, required: true
  slot :inner_block, required: true

  def doc_link(assigns) do
    ~H"""
    <.link navigate={Docs.href(@topic)} class="link link-primary">{render_slot(@inner_block)}</.link>
    """
  end

  ## Valores vigentes (RF-11.4): el manual nunca copia a mano una regla del juego.

  @doc false
  @spec rule(atom()) :: term()
  def rule(key), do: GameRules.get(key)

  @doc false
  @spec pct(number(), non_neg_integer()) :: String.t()
  def pct(value, decimals \\ 2),
    do: "#{:erlang.float_to_binary(value * 100 / 1, decimals: decimals)} %"

  @doc false
  @spec isk(number()) :: String.t()
  def isk(value), do: EthWeb.Format.compact(value)
end
