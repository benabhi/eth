defmodule EthWeb.DocsLiveTest do
  use EthWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias EthWeb.{Docs, DocsPages, Glossary}

  describe "manual al día (RF-11.4)" do
    test "cada tema de la aplicación apunta a una página y un encabezado que existen" do
      for {topic, {page, anchor}} <- Docs.topics() do
        assert Docs.page?(page),
               "el tema #{inspect(topic)} apunta a una página inexistente: #{page}"

        ids = page |> DocsPages.headings() |> Enum.map(&elem(&1, 0))

        assert anchor in ids,
               "el tema #{inspect(topic)} apunta a ##{anchor}, que no existe en #{page} (hay: #{Enum.join(ids, ", ")})"
      end
    end

    test "cada enlace del manual a otro tema es válido" do
      for {slug, _title, _group} <- Docs.pages() do
        html = DocsPages.page_html(slug)
        assert html != "", "la página #{slug} no renderiza"

        for [_, page, anchor] <- Regex.scan(~r{href="/docs/([a-z0-9-]+)#([a-z0-9-]+)"}, html) do
          assert anchor in (page |> DocsPages.headings() |> Enum.map(&elem(&1, 0))),
                 "#{slug} enlaza a /docs/#{page}##{anchor}, que no existe"
        end
      end
    end

    test "cada tema tiene un resumen para su \"?\" (RNF-5.14)" do
      for {topic, _target} <- Docs.topics() do
        summary = Docs.summary(topic)
        assert is_binary(summary) and String.length(summary) >= 20, "#{topic} sin resumen"
      end
    end

    test "ningún \"?\" de la aplicación queda solo con el enlace al manual", %{conn: conn} do
      paths =
        ~w(/ /station /orders /run /docs /settings /settings/ships /settings/rules
           /settings/radar /settings/markets /settings/notifications /settings/setup
           /settings/backup /control /control/market /control/radar /control/characters
           /control/logs /control/esi)

      checked =
        for path <- paths, reduce: 0 do
          count ->
            {:ok, _view, html} = live(conn, path)
            tooltips = html |> LazyHTML.from_document() |> LazyHTML.query("[role=tooltip]")
            assert_tooltips_have_text(tooltips, path)
            count + Enum.count(tooltips)
        end

      # Que el test no pase en vacío: las pantallas tienen decenas de "?".
      assert checked > 30
    end

    defp assert_tooltips_have_text(tooltips, path) do
      Enum.each(tooltips, fn tooltip ->
        # Texto de ayuda sin el título y sin el enlace al manual.
        text =
          tooltip
          |> LazyHTML.query("[data-tip-text]")
          |> LazyHTML.text()
          |> String.trim()

        assert text != "", "tooltip sin texto en #{path}: #{LazyHTML.to_html(tooltip)}"
      end)
    end

    test "cada término del glosario se explica solo, enlaza bien y tiene su ancla" do
      entries = Glossary.entries()
      keys = Enum.map(entries, & &1.key)
      assert keys == Enum.uniq(keys), "claves repetidas en el glosario"

      html = DocsPages.page_html("glosario")

      for entry <- entries do
        assert String.length(entry.definition) >= 20, "#{entry.key}: definición muy corta"
        assert is_nil(entry.topic) or Map.has_key?(Docs.topics(), entry.topic)
        assert html =~ ~s(id="#{Glossary.anchor(entry.key)}"), "#{entry.key} sin ancla"
      end

      assert_raise ArgumentError, fn -> Glossary.fetch!(:no_existe) end
    end

    test "un tema desconocido falla en vez de dejar un enlace roto" do
      assert_raise ArgumentError, fn -> Docs.href(:no_existe) end
    end

    test "las páginas muestran los valores vigentes de las reglas del juego" do
      assert DocsPages.plain_text("impuestos") =~ "7.5 %"
      assert DocsPages.plain_text("impuestos") =~ "3.375 %"
    end
  end

  describe "vista del manual (RF-11.1)" do
    test "abre la primera página y navega por el índice", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/docs")
      assert has_element?(view, "#docs-page h1", "Instalar y registrar tu app de EVE")
      assert has_element?(view, "#docs-toc a[aria-current='page']")
      assert has_element?(view, "#docs-next")

      {:ok, view, _html} = live(conn, ~p"/docs/tvs-certeza")
      assert has_element?(view, "#docs-page #certeza")
      assert has_element?(view, "#docs-prev")
    end

    test "la búsqueda encuentra términos y omite tildes", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/docs")
      view |> form("#docs-search", q: "competidores") |> render_change()
      assert has_element?(view, "#docs-results", "Station trading")

      view |> form("#docs-search", q: "linea base") |> render_change()
      assert has_element?(view, "#docs-results", "Radar")
    end

    test "una sigla del glosario aparece primero y no coincide dentro de otra palabra", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/docs")
      view |> form("#docs-search", q: "SDE") |> render_change()

      assert has_element?(view, "#docs-term-sde", "datos fijos de EVE")
      # "desde" contiene "sde": la primera página no la menciona y no debe aparecer.
      refute has_element?(view, "#docs-results", "Instalar y registrar tu app de EVE")

      assert has_element?(
               view,
               "#docs-term-sde[href='/docs/glosario#g-sde']"
             )
    end

    test "una página inexistente vuelve al inicio del manual", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/docs"}}} = live(conn, ~p"/docs/no-existe")
    end
  end
end
