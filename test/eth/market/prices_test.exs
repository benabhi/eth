defmodule Eth.Market.PricesTest do
  use Eth.DataCase, async: false

  alias Eth.Esi.Budget
  alias Eth.EsiStub
  alias Eth.Market.Prices

  setup do
    Req.Test.set_req_test_to_shared()
    on_exit(&Req.Test.set_req_test_to_private/0)
    :ets.delete_all_objects(:eth_esi_budget)
    Budget.resume_all()
    File.rm_rf!(Path.join(Eth.Storage.data_dir(), "market"))
    start_supervised!({Task.Supervisor, name: Eth.Market.TaskSupervisor})
    :ok
  end

  @body [
    %{"type_id" => 34, "average_price" => 3.85, "adjusted_price" => 4.1},
    %{"type_id" => 35, "adjusted_price" => 12}
  ]

  test "interpreta la respuesta de ESI" do
    assert Prices.parse(@body) == [{34, 3.85, 4.1}, {35, nil, 12.0}]
  end

  test "descarga, publica en ETS y restaura lo guardado al reiniciar" do
    test_pid = self()

    Req.Test.stub(Eth.Esi.Client, fn conn ->
      send(test_pid, {:request, Map.new(conn.req_headers)["if-none-match"]})

      EsiStub.respond(conn, 200, @body,
        etag: ~s("p1"),
        expires: DateTime.add(DateTime.utc_now(), 3600, :second)
      )
    end)

    start_supervised!(Prices)
    assert_receive {:request, nil}, 1_000
    wait_until(fn -> Prices.average(34) == 3.85 end)

    assert Prices.adjusted(35) == 12.0
    assert Prices.average(35) == nil
    assert Prices.average(99) == nil

    # Reinicio: los precios guardados están disponibles y no se vuelve a pedir antes de Expires.
    stop_supervised!(Prices)
    start_supervised!(Prices)
    assert Prices.average(34) == 3.85
    refute_receive {:request, _}, 200
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
