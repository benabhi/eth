defmodule Eth.Esi.ClientTest do
  # No es async: el presupuesto de ESI es global (tabla ETS compartida).
  use ExUnit.Case, async: false

  alias Eth.Esi
  alias Eth.Esi.{Budget, Response}
  alias Eth.EsiStub

  setup do
    Budget.resume_all()
    :ets.delete_all_objects(:eth_esi_budget)
    :ok
  end

  describe "requests" do
    test "envía User-Agent, fecha de compatibilidad e If-None-Match" do
      Req.Test.stub(Esi.Client, fn conn ->
        headers = Map.new(conn.req_headers)
        send(self(), {:headers, headers, conn.query_string})
        EsiStub.respond(conn, 200, [])
      end)

      assert {:ok, %Response{status: 200}} = Esi.market_orders(10_000_002, 3, ~s("abc"))
      assert_received {:headers, headers, query}

      assert headers["user-agent"] =~
               ~r{^EVETradeHunter/\S+ \(.*\+https://github.com/benabhi/eth\) Req/}

      assert headers["x-compatibility-date"] == "2026-09-01"
      assert headers["if-none-match"] == ~s("abc")
      assert query =~ "page=3"
      assert query =~ "order_type=all"
    end

    test "interpreta los metadatos de caché, paginación y rate limit" do
      expires = ~U[2026-09-29 00:02:18Z]

      Req.Test.stub(Esi.Client, fn conn ->
        EsiStub.respond(conn, 200, [%{"order_id" => 1}],
          expires: expires,
          last_modified: ~U[2026-09-28 23:57:18Z],
          etag: ~s("e1"),
          pages: 405,
          rate_limit: {"market-order", 11_998}
        )
      end)

      assert {:ok, resp} = Esi.market_orders(10_000_002, 1)
      assert resp.body == [%{"order_id" => 1}]
      assert resp.expires == expires
      assert resp.last_modified == ~U[2026-09-28 23:57:18Z]
      assert resp.etag == ~s("e1")
      assert resp.pages == 405

      assert resp.rate_limit == %{
               group: "market-order",
               limit: 12_000,
               window_s: 900,
               remaining: 11_998,
               used: 2
             }

      assert Budget.remaining_ratio("market-order") == 11_998 / 12_000
    end

    test "sin conexión libre en el pool es una cola local, no un error de ESI" do
      message =
        "Finch was unable to provide a connection within the timeout due to excess " <>
          "queuing for connections."

      Req.Test.stub(Esi.Client, fn _conn -> raise message end)

      assert {:error, :pool_busy} = Esi.market_orders(10_000_002, 1, nil)
      assert Esi.Client.pool_busy?(%RuntimeError{message: message})
      refute Esi.Client.pool_busy?(%RuntimeError{message: "otro error"})
    end

    test "un 304 es una respuesta válida sin cuerpo" do
      Req.Test.stub(Esi.Client, fn conn -> EsiStub.respond(conn, 304, nil, etag: ~s("e1")) end)

      assert {:ok, %Response{status: 304, body: nil, etag: ~s("e1")}} =
               Esi.market_orders(10_000_002, 2, ~s("e1"))
    end

    test "pide el historial de un tipo en una región y los precios globales" do
      Req.Test.stub(Esi.Client, fn conn ->
        send(self(), {:request, conn.request_path, conn.query_string})
        EsiStub.respond(conn, 200, [], expires: ~U[2026-09-30 11:05:00Z])
      end)

      assert {:ok, %Response{expires: ~U[2026-09-30 11:05:00Z]}} =
               Esi.market_history(10_000_002, 34)

      assert_received {:request, "/markets/10000002/history", "type_id=34"}

      assert {:ok, %Response{}} = Esi.market_prices()
      assert_received {:request, "/markets/prices", ""}
    end

    test "los errores HTTP y de transporte se devuelven como error" do
      Req.Test.stub(Esi.Client, fn conn -> EsiStub.respond(conn, 502, %{"error" => "bad"}) end)
      assert {:error, {:http, %Response{status: 502}}} = Esi.status()

      Req.Test.stub(Esi.Client, &Req.Test.transport_error(&1, :timeout))
      assert {:error, {:transport, %Req.TransportError{reason: :timeout}}} = Esi.status()
    end
  end

  describe "presupuesto" do
    test "un 429 pausa solo ese grupo durante Retry-After" do
      Req.Test.stub(Esi.Client, fn conn ->
        EsiStub.respond(conn, 429, %{"error" => "limit"},
          rate_limit: {"market-order", 0},
          headers: [{"retry-after", "120"}]
        )
      end)

      assert {:error, {:http, %Response{status: 429}}} = Esi.market_orders(10_000_002, 1)
      assert {:error, {:rate_limited, _until}} = Esi.market_orders(10_000_002, 1)
      assert Budget.check("status") == :ok
    end

    test "un error limit bajo pausa todo ESI hasta el reset" do
      Req.Test.stub(Esi.Client, fn conn ->
        EsiStub.respond(conn, 404, %{"error" => "no"},
          headers: [{"x-esi-error-limit-remain", "15"}, {"x-esi-error-limit-reset", "30"}]
        )
      end)

      assert {:error, {:http, _}} = Esi.region_ids()
      assert {:error, {:paused, until}} = Esi.status()
      assert DateTime.diff(until, DateTime.utc_now()) in 28..31
    end

    test "un 420 pausa todo ESI" do
      Req.Test.stub(Esi.Client, fn conn -> EsiStub.respond(conn, 420, %{"error" => "limited"}) end)

      assert {:error, {:http, %Response{status: 420}}} = Esi.status()
      assert {:error, {:paused, _}} = Esi.region_ids()
    end

    test "la pausa global manual bloquea y se levanta" do
      Budget.pause_all(DateTime.add(DateTime.utc_now(), 600, :second))
      assert {:error, {:paused, _}} = Esi.status()

      Budget.resume_all()
      Req.Test.stub(Esi.Client, fn conn -> EsiStub.respond(conn, 200, %{"players" => 1}) end)
      assert {:ok, _} = Esi.status()
    end
  end
end
