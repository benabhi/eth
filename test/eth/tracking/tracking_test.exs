defmodule Eth.TrackingTest do
  use Eth.DataCase, async: false

  alias Eth.Characters
  alias Eth.Characters.Session
  alias Eth.Engine.{Evaluator, Fees, Query, Summary}
  alias Eth.EngineFixture, as: F
  alias Eth.Market.TableOwner
  alias Eth.Tracking
  alias Eth.Tracking.{Run, RunMonitor}

  @moduletag :tmp_dir
  @moduletag :capture_log

  @id 2_112_345_678
  @tritanium 34

  setup %{tmp_dir: tmp_dir} do
    :ok = F.load_sde(tmp_dir)
    start_supervised!(TableOwner)
    start_supervised!(Eth.Tracking.Supervisor)
    if :ets.whereis(:eth_engine_summaries) == :undefined, do: Summary.create_table()

    {:ok, _} =
      Characters.upsert_login(%{
        character_id: @id,
        name: "Hernan Test",
        owner_hash: "hash",
        scopes: Eth.Sso.scopes(),
        refresh_token: "refresh"
      })

    Phoenix.PubSub.subscribe(Eth.PubSub, Tracking.topic(@id))
    :ok
  end

  # Tritanium de Jita 4-4 a una estructura de Perimeter; devuelve la fila personalizada.
  defp market_row(buy_price \\ 5.0) do
    F.publish_orders([
      {:sell, @tritanium, 4.0, 100_000, F.jita_44(), F.jita(), []},
      {:buy, @tritanium, buy_price, 100_000, F.perimeter_station(), F.perimeter(), []}
    ])

    [{source, entry}] = TableOwner.all()
    types = Summary.replace(source, entry.tid)

    src = %{
      source: source,
      tid: entry.tid,
      region_id: 10_000_002,
      last_modified: DateTime.utc_now()
    }

    [opp] = Evaluator.run([src], types, tax: Fees.sales_tax(4), min_profit: 1_000)

    query = %{route_mode: :secure, cargo_m3: nil, min_profit: 1_000, base_system_id: F.jita()}
    {Query.personalize(opp, Map.merge(Query.defaults(), query), DateTime.utc_now()), query}
  end

  defp session_update(resource, context) do
    Phoenix.PubSub.broadcast(
      Eth.PubSub,
      Session.topic(@id),
      {:character, @id, {:updated, resource}, %{context: context}}
    )
  end

  defp wait_status(run_id, status, tries \\ 100) do
    case Tracking.get(run_id) do
      %Run{status: ^status} = run ->
        run

      _other when tries > 0 ->
        Process.sleep(20)
        wait_status(run_id, status, tries - 1)

      other ->
        flunk("el viaje no llegó a #{status}: #{inspect(other && other.status)}")
    end
  end

  test "inicia un viaje con el plan congelado y admite uno activo por personaje" do
    {row, query} = market_row()
    assert {:ok, run} = Tracking.start(@id, row, query)
    assert_receive {:run, %Run{status: "planned"}, nil}

    assert run.plan["type_name"] == "Tritanium"
    assert run.plan["quantity"] == 100_000
    assert run.plan["destination_location_id"] == F.perimeter_station()
    assert run.predicted_profit == row.profit
    assert Tracking.active(@id).id == run.id

    # El camino que falta (mapa del Centro de control): sin ubicación, desde el origen.
    path = Tracking.remaining_path(run)
    assert hd(path) == F.jita()
    assert List.last(path) == F.perimeter()

    assert {:error, :already_active} = Tracking.start(@id, row, query)
  end

  test "sigue las etapas con la ubicación y el saldo, y reconcilia el cierre" do
    {row, query} = market_row()
    {:ok, run} = Tracking.start(@id, row, query)
    Repo.update_all(from(r in Run, where: r.id == ^run.id), set: [wallet_at_start: 1.0e9])
    RunMonitor.stop(run.id)
    RunMonitor.start(Tracking.get(run.id))

    jita = %{solar_system_id: F.jita(), station_id: F.jita_44()}
    space = %{solar_system_id: F.perimeter(), station_id: nil}
    perimeter = %{solar_system_id: F.perimeter(), structure_id: F.perimeter_station()}

    session_update(:location, %{location: jita})
    wait_status(run.id, "to_origin")

    session_update(:wallet, %{location: jita, wallet: 1.0e9 - row.cost})
    wait_status(run.id, "bought")

    session_update(:location, %{location: space})
    wait_status(run.id, "in_transit")

    session_update(:location, %{location: perimeter})
    wait_status(run.id, "at_destination")

    # Transacciones de la billetera (en producción llegan de ESI con 1 h de caché).
    now = DateTime.utc_now()

    Tracking.store_transactions(@id, [
      tx(1, true, row.quantity, 4.0, F.jita_44(), now),
      tx(2, false, row.quantity, 5.0, F.perimeter_station(), now)
    ])

    session_update(:wallet, %{location: perimeter, wallet: 1.0e9 - row.cost + row.revenue})
    closed = wait_status(run.id, "closed")

    assert closed.stages |> Map.keys() |> Enum.sort() ==
             Enum.sort(~w(planned to_origin bought in_transit at_destination closed))

    run = wait_result(run.id)
    assert_in_delta run.realized_profit, row.profit, 1.0
    assert run.result["complete"]
  end

  test "confirmación manual, revalidación y abortar" do
    {row, query} = market_row()
    {:ok, run} = Tracking.start(@id, row, query)
    assert {:ok, %Run{status: "bought"}} = Tracking.confirm(run, :bought)

    # El mercado cambia: la compra del destino baja a 4,5 y el beneficio cae.
    market_row(4.5)

    send(
      Eth.Tracking.Registry |> Registry.lookup(run.id) |> hd() |> elem(0),
      {:opportunities_updated, %{}}
    )

    assert_receive {:run, _run, {:alert, "El beneficio proyectado cayó " <> _}}, 2_000

    run = Tracking.abort(Tracking.get(run.id))
    assert run.status == "aborted"
    assert Tracking.active(@id) == nil
  end

  defp tx(id, is_buy, quantity, price, location, date) do
    %{
      "transaction_id" => id,
      "date" => DateTime.to_iso8601(date),
      "type_id" => @tritanium,
      "quantity" => quantity,
      "unit_price" => price,
      "is_buy" => is_buy,
      "location_id" => location,
      "journal_ref_id" => id,
      "client_id" => 1,
      "is_personal" => true
    }
  end

  defp wait_result(run_id, tries \\ 100) do
    case Tracking.get(run_id) do
      %Run{result: %{}} = run ->
        run

      _other when tries > 0 ->
        Process.sleep(20)
        wait_result(run_id, tries - 1)

      _other ->
        flunk("el viaje no se reconcilió")
    end
  end
end
