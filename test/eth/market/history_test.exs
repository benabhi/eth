defmodule Eth.Market.HistoryTest do
  use Eth.DataCase, async: false

  alias Eth.Esi.Budget
  alias Eth.EsiStub
  alias Eth.Market.{History, HistoryStat, HistoryStats}

  setup do
    Req.Test.set_req_test_to_shared()
    on_exit(&Req.Test.set_req_test_to_private/0)
    :ets.delete_all_objects(:eth_esi_budget)
    Budget.resume_all()
    start_supervised!({Task.Supervisor, name: Eth.Market.TaskSupervisor})
    Phoenix.PubSub.subscribe(Eth.PubSub, History.topic())
    :ok
  end

  defp stub_history(test_pid) do
    as_of = HistoryStats.last_day(DateTime.utc_now())

    Req.Test.stub(Eth.Esi.Client, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      [_, "markets", region, "history"] = String.split(conn.request_path, "/")
      type = conn.query_params["type_id"]
      send(test_pid, {:history_request, String.to_integer(region), String.to_integer(type)})

      if type == "999" do
        EsiStub.respond(conn, 404, %{"error" => "Type not found"})
      else
        body = [%{"date" => Date.to_iso8601(as_of), "average" => 10.0, "volume" => 5}]
        EsiStub.respond(conn, 200, body)
      end
    end)
  end

  defp put_rule(key, value) do
    previous = Application.get_env(:eth, Eth.GameRules)
    Application.put_env(:eth, Eth.GameRules, Keyword.put(previous, key, value))
    on_exit(fn -> Application.put_env(:eth, Eth.GameRules, previous) end)
  end

  test "atiende la demanda por prioridad, guarda en ETS y PostgreSQL y no repite pares vigentes" do
    stub_history(self())
    put_rule(:history_concurrency, 1)
    start_supervised!(History)

    History.demand([{{10_000_002, 34}, 1.0}, {{10_000_043, 35}, 5.0}, {{10_000_002, 999}, 0.5}])

    assert_receive {:history_request, 10_000_043, 35}, 1_000
    assert_receive {:history_request, 10_000_002, 34}, 1_000
    assert_receive {:history_request, 10_000_002, 999}, 1_000
    assert_receive {:history_updated, _n}, 1_000

    wait_until(fn -> History.stats(10_000_002, 999) != nil end)
    assert %{days_traded_30d: 1, median_7d: 10.0} = History.stats(10_000_043, 35)
    # Tipo sin mercado: estadísticas vacías (no se vuelve a pedir hoy).
    assert %{days_traded_30d: 0} = History.stats(10_000_002, 999)
    assert Repo.aggregate(HistoryStat, :count) == 3

    # Una nueva demanda con los mismos pares no genera requests.
    History.demand([{{10_000_002, 34}, 1.0}, {{10_000_043, 35}, 5.0}])
    refute_receive {:history_request, _, _}, 200
    assert %{pending: 0, cached: 3} = History.status()
  end

  test "respeta el máximo de requests por minuto" do
    stub_history(self())
    put_rule(:history_max_per_min, 2)
    start_supervised!(History)

    History.demand(for type <- 1..5, do: {{10_000_002, type}, type})

    assert_receive {:history_request, _, 5}, 1_000
    assert_receive {:history_request, _, 4}, 1_000
    refute_receive {:history_request, _, _}, 300
    assert %{last_minute: 2, pending: 3} = History.status()
  end

  test "al arrancar recarga lo guardado en PostgreSQL" do
    stats = HistoryStats.compute([], HistoryStats.last_day(DateTime.utc_now()))
    Repo.insert_all(HistoryStat, [HistoryStat.row(10_000_002, 34, stats, DateTime.utc_now())])

    start_supervised!(History)
    wait_until(fn -> History.stats(10_000_002, 34) != nil end)
    assert History.stats(10_000_002, 34).as_of == stats.as_of
  end

  defp wait_until(fun, tries \\ 50) do
    cond do
      fun.() ->
        :ok

      tries == 0 ->
        flunk("la condición no se cumplió a tiempo")

      true ->
        Process.sleep(20)
        wait_until(fun, tries - 1)
    end
  end
end
