defmodule EthWeb.DocsLive do
  @moduledoc """
  Manual integrado (RF-11.1): índice por grupos, búsqueda en títulos y contenido, la página
  con sus secciones enlazables, "En esta página" y navegación anterior/siguiente.

  Implementa: RF-11.1, RF-11.2.
  """
  use EthWeb, :live_view

  alias EthWeb.{Docs, DocsPages, Glossary}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:query, "")
     |> assign(:results, nil)
     |> assign(:terms, [])
     |> assign(:index, search_index())}
  end

  @impl true
  def handle_params(%{"page" => slug}, _uri, socket) do
    if Docs.page?(slug),
      do: {:noreply, show_page(socket, slug)},
      else: {:noreply, push_navigate(socket, to: ~p"/docs")}
  end

  # `/docs` abre la primera página del manual.
  def handle_params(_params, _uri, socket) do
    {slug, _title, _group} = hd(Docs.pages())
    {:noreply, show_page(socket, slug)}
  end

  defp show_page(socket, slug) do
    socket
    |> assign(:slug, slug)
    |> assign(:page_title, gettext("Documentación · %{title}", title: Docs.title(slug)))
    |> assign(:headings, DocsPages.headings(slug))
    |> assign(:neighbors, Docs.neighbors(slug))
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    {:noreply,
     assign(socket,
       query: q,
       results: search(socket.assigns.index, q),
       terms: search_terms(q)
     )}
  end

  # Índice de búsqueda: título y texto plano de cada página (se arma una vez por visita).
  defp search_index do
    for {slug, title, group} <- Docs.pages() do
      %{
        slug: slug,
        title: title,
        group: group,
        text: normalize(title <> " " <> DocsPages.plain_text(slug))
      }
    end
  end

  defp search(_index, q) when byte_size(q) < 2, do: nil

  # Coincidencia por comienzo de palabra: "sde" no debe encontrar "desde".
  defp search(index, q) do
    needle = normalize(q)
    for entry <- index, String.contains?(entry.text, needle), do: entry
  end

  # Términos del glosario cuyo nombre o sinónimo empieza con la búsqueda: van primero,
  # con su definición a la vista.
  defp search_terms(q) when byte_size(q) < 2, do: []

  defp search_terms(q) do
    needle = normalize(q)

    for entry <- Glossary.entries(),
        Enum.any?([entry.term | entry.aliases], &String.contains?(normalize(&1), needle)),
        do: entry
  end

  # Minúsculas, sin acentos y con las palabras separadas por un espacio (también al
  # principio), para buscar " palabra" como comienzo de palabra.
  defp normalize(text) do
    text
    |> String.downcase()
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/\p{Mn}/u, "")
    |> String.replace(~r/[^\p{L}\p{N}\/]+/u, " ")
    |> String.trim()
    |> then(&(" " <> &1))
  end

  defp groups do
    Docs.pages()
    |> Enum.chunk_by(&elem(&1, 2))
    |> Enum.map(fn [{_, _, group} | _] = pages -> {group, pages} end)
  end
end
