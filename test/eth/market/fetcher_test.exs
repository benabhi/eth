defmodule Eth.Market.FetcherTest do
  # Global: presupuesto de ESI compartido, stubs en modo compartido (las páginas se piden
  # desde tareas) y catálogo de snapshots con nombre.
  use ExUnit.Case, async: false

  alias Eth.Esi.Budget
  alias Eth.EsiStub
  alias Eth.Market.{Fetcher, TableOwner}

  @region 10_000_002
  @lm ~U[2026-09-29 00:00:00Z]
  @lm_old ~U[2026-09-28 23:55:00Z]
  @expires ~U[2026-09-29 00:05:00Z]

  setup do
    Req.Test.set_req_test_to_shared()
    on_exit(&Req.Test.set_req_test_to_private/0)
    :ets.delete_all_objects(:eth_esi_budget)
    Budget.resume_all()
    start_supervised!(TableOwner)
    :ok
  end

  defp order(id, type_id, buy?, price) do
    %{
      "order_id" => id,
      "type_id" => type_id,
      "is_buy_order" => buy?,
      "price" => price,
      "location_id" => 60_003_760,
      "system_id" => 30_000_142,
      "volume_remain" => 10,
      "volume_total" => 10,
      "min_volume" => 1,
      "range" => if(buy?, do: "region", else: "station"),
      "issued" => "2026-09-28T12:00:00Z",
      "duration" => 90
    }
  end

  # Páginas: mapa página => lista de órdenes. `lm` permite simular páginas de otra generación.
  defp stub_pages(pages, opts \\ []) do
    test = self()
    lm_for = Keyword.get(opts, :lm_for, fn _page, _call -> @lm end)
    counter = :counters.new(1, [])

    Req.Test.stub(Eth.Esi.Client, fn conn ->
      :counters.add(counter, 1, 1)
      params = Plug.Conn.fetch_query_params(conn).query_params
      page = String.to_integer(params["page"])
      etag = ~s("p#{page}")
      send(test, {:requested, page, Plug.Conn.get_req_header(conn, "if-none-match")})

      status =
        if Plug.Conn.get_req_header(conn, "if-none-match") == [etag] and opts[:not_modified],
          do: 304,
          else: 200

      EsiStub.respond(conn, status, Map.fetch!(pages, page),
        pages: map_size(pages),
        etag: etag,
        last_modified: lm_for.(page, :counters.get(counter, 1)),
        expires: @expires,
        rate_limit: {"market-order", 11_000}
      )
    end)
  end

  test "descarga todas las páginas y publica un libro ordenado" do
    stub_pages(%{
      1 => [order(1, 34, false, 5.0), order(2, 34, true, 4.0)],
      2 => [order(3, 34, false, 4.5), order(4, 34, true, 4.2)],
      3 => [order(5, 35, false, 100.0)]
    })

    assert {:ok, meta} = Fetcher.fetch(@region)
    assert meta.pages == 3
    assert meta.orders == 5
    assert meta.sell_orders == 3
    assert meta.buy_orders == 2
    assert meta.last_modified == @lm
    assert meta.expires == @expires
    assert meta.generation == 1

    %{tid: tid} = TableOwner.current({:region, @region})

    sells = :ets.match_object(tid, {{34, :sell, :_, :_}, :_, :_, :_, :_, :_, :_, :_, :_})
    buys = :ets.match_object(tid, {{34, :buy, :_, :_}, :_, :_, :_, :_, :_, :_, :_, :_})

    # Ventas de menor a mayor precio; compras de mayor a menor.
    assert Enum.map(sells, &elem(&1, 7)) == [4.5, 5.0]
    assert Enum.map(buys, &elem(&1, 7)) == [4.2, 4.0]
  end

  test "avisa el progreso desde la primera página" do
    stub_pages(%{
      1 => [order(1, 34, false, 5.0)],
      2 => [order(2, 34, true, 4.0)],
      3 => [order(3, 35, false, 100.0)]
    })

    assert {:ok, _meta} = Fetcher.fetch(@region, self())
    assert_received {:fetch_progress, @region, 1, 3}
    assert_received {:fetch_progress, @region, 3, 3}
    refute_received {:fetch_progress, @region, 2, 3}
  end

  test "reutiliza con 304 las páginas sin cambios y publica una nueva generación" do
    pages = %{1 => [order(1, 34, false, 5.0)], 2 => [order(2, 34, true, 4.0)]}
    stub_pages(pages)
    assert {:ok, %{generation: 1}} = Fetcher.fetch(@region)

    stub_pages(pages, not_modified: true)
    assert {:ok, meta} = Fetcher.fetch(@region)

    assert meta.generation == 2
    assert meta.not_modified_pages == 2
    assert meta.orders == 2
    assert_received {:requested, 1, [~s("p1")]}
  end

  test "vuelve a pedir las páginas de una generación vieja de la caché" do
    # En la primera pasada la página 2 viene de un snapshot anterior; al reintentar, bien.
    lm_for = fn
      2, call when call <= 3 -> @lm_old
      _page, _call -> @lm
    end

    stub_pages(%{1 => [order(1, 34, false, 5.0)], 2 => [order(2, 34, true, 4.0)]}, lm_for: lm_for)

    assert {:ok, meta} = Fetcher.fetch(@region)
    assert meta.orders == 2
    assert meta.last_modified == @lm
  end

  test "descarta el ciclo si las páginas nunca coinciden" do
    lm_for = fn
      2, _call -> @lm_old
      _page, _call -> @lm
    end

    stub_pages(%{1 => [order(1, 34, false, 5.0)], 2 => [order(2, 34, true, 4.0)]}, lm_for: lm_for)

    assert {:error, :inconsistent} = Fetcher.fetch(@region)
    assert TableOwner.current({:region, @region}) == nil
  end

  test "un error en cualquier página aborta sin publicar" do
    Req.Test.stub(Eth.Esi.Client, fn conn ->
      params = Plug.Conn.fetch_query_params(conn).query_params

      if params["page"] == "1",
        do: EsiStub.respond(conn, 200, [order(1, 34, false, 5.0)], pages: 2, last_modified: @lm),
        else: EsiStub.respond(conn, 502, %{"error" => "bad gateway"})
    end)

    assert {:error, {:http, 502}} = Fetcher.fetch(@region)
    assert TableOwner.current({:region, @region}) == nil
  end
end
