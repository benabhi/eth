defmodule Eth.Market.StructuresTest do
  use Eth.DataCase, async: false

  alias Eth.{Characters, EngineFixture, EsiStub}
  alias Eth.Esi.Budget
  alias Eth.Market.{StructurePoller, Structures, TableOwner}

  @moduletag :tmp_dir
  @moduletag :capture_log

  @alice 2_112_000_001
  @bob 2_112_000_002
  @structure 1_035_466_617_946
  @perimeter 30_000_144

  setup %{tmp_dir: tmp_dir} do
    :ok = EngineFixture.load_sde(tmp_dir)
    Req.Test.set_req_test_to_shared()
    on_exit(&Req.Test.set_req_test_to_private/0)
    :ets.delete_all_objects(:eth_esi_budget)
    Budget.resume_all()

    for {id, name} <- [{@alice, "Alice"}, {@bob, "Bob"}] do
      {:ok, _} =
        Characters.upsert_login(%{
          character_id: id,
          name: name,
          owner_hash: "hash-#{id}",
          scopes: Eth.Sso.scopes(),
          refresh_token: "refresh-#{id}"
        })
    end

    Application.put_env(:eth, :character_token_fun, &{:ok, "token-#{&1}"})
    on_exit(fn -> Application.delete_env(:eth, :character_token_fun) end)
    :ok
  end

  describe "registro y selección" do
    test "sincroniza la lista pública y guarda los datos de cada estructura" do
      Structures.sync_public([1, 2])

      Structures.put_info(1, %{
        "name" => "Uno",
        "solar_system_id" => @perimeter,
        "type_id" => 35_832
      })

      assert [%{id: 2}] = Structures.unresolved()
      assert %{name: "Uno", region_id: 10_000_002, public_market: true} = Structures.get(1)

      Structures.sync_public([2])
      refute Structures.get(1).public_market
    end

    test "top por órdenes en regiones habilitadas más las seguidas por el operador" do
      Structures.sync_public([1, 2, 3])

      for {id, orders} <- [{1, 50}, {2, 500}, {3, nil}] do
        Structures.put_info(id, %{"name" => "E#{id}", "solar_system_id" => @perimeter})
        if orders, do: Structures.put_orders_count(id, orders)
      end

      previous = Application.get_env(:eth, Eth.GameRules)
      Application.put_env(:eth, Eth.GameRules, Keyword.put(previous, :structures_top, 2))
      Eth.GameRules.reload()

      on_exit(fn ->
        Application.put_env(:eth, Eth.GameRules, previous)
        Eth.GameRules.reload()
      end)

      assert Enum.map(Structures.selection(), & &1.id) == [2, 1]

      {:ok, _} = Structures.follow(3)
      assert 3 in Enum.map(Structures.selection(), & &1.id)
    end

    test "CA: un 403 no se vuelve a intentar con ese personaje antes de 24 h" do
      now = DateTime.utc_now()
      assert Structures.may_try?(nil, now)

      forbidden = %Eth.Market.StructureAccess{status: "forbidden", checked_at: now}
      refute Structures.may_try?(forbidden, DateTime.add(now, 23 * 3600))
      assert Structures.may_try?(forbidden, DateTime.add(now, 24 * 3600))
    end
  end

  describe "poller" do
    setup do
      start_supervised!(TableOwner)
      start_supervised!({Registry, keys: :unique, name: Eth.Market.Registry})
      start_supervised!({Task.Supervisor, name: Eth.Market.TaskSupervisor})
      Structures.follow(@structure)

      Structures.put_info(@structure, %{
        "name" => "Perimeter Keepstar",
        "solar_system_id" => @perimeter
      })

      :ok
    end

    defp order(id, buy?) do
      %{
        "order_id" => id,
        "type_id" => 34,
        "is_buy_order" => buy?,
        "price" => 5.0,
        "location_id" => @structure,
        "volume_remain" => 10,
        "volume_total" => 10,
        "min_volume" => 1,
        "range" => "station",
        "issued" => "2026-09-28T12:00:00Z",
        "duration" => 90
      }
    end

    test "con un 403 marca al personaje sin acceso y descarga con el siguiente" do
      test_pid = self()

      Req.Test.stub(Eth.Esi.Client, fn conn ->
        "Bearer token-" <> char = Map.new(conn.req_headers)["authorization"]
        send(test_pid, {:request, String.to_integer(char)})

        if char == "#{@alice}" do
          EsiStub.respond(conn, 403, %{"error" => "Forbidden"})
        else
          EsiStub.respond(conn, 200, [order(1, false), order(2, true)],
            pages: 1,
            last_modified: DateTime.utc_now(),
            expires: DateTime.add(DateTime.utc_now(), 300, :second)
          )
        end
      end)

      start_supervised!({StructurePoller, Structures.get(@structure)})

      # Alice (primera por nombre) recibe 403; se pasa a Bob sin esperar.
      assert_receive {:request, @alice}, 15_000
      assert_receive {:request, @bob}, 2_000
      wait_until(fn -> TableOwner.current({:structure, @structure}) != nil end)

      %{tid: tid, meta: meta} = TableOwner.current({:structure, @structure})
      assert :ets.info(tid, :size) == 2
      # Las órdenes de estructura no traen system_id: se completa con el de la estructura.
      assert [{_key, @structure, @perimeter, _, _, _, _, _, _} | _] = :ets.tab2list(tid)
      assert meta.region_id == 10_000_002

      access = Structures.access_map()
      assert %{status: "forbidden"} = access[{@structure, @alice}]
      assert %{status: "ok"} = access[{@structure, @bob}]
      assert Structures.get(@structure).orders_count == 2
      assert %{status: :cached, character_id: @bob} = StructurePoller.status(@structure)
    end
  end

  defp wait_until(fun, tries \\ 100) do
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
