defmodule Eth.Tracking.HunterMilestonesTest do
  # El Dispatcher de notificaciones es un proceso con nombre: no async.
  use Eth.DataCase, async: false

  alias Eth.{Notifications, Repo, Tracking}
  alias Eth.Notifications.Dispatcher
  alias Eth.Tracking.Run

  @id 2_112_000_777

  setup do
    {:ok, _} =
      Eth.Characters.upsert_login(%{
        character_id: @id,
        name: "Hernan Test",
        owner_hash: "hash",
        scopes: Eth.Sso.scopes(),
        refresh_token: "refresh"
      })

    start_supervised!(Dispatcher)
    Phoenix.PubSub.subscribe(Eth.PubSub, Notifications.topic())
    :ok
  end

  defp closed_run(predicted) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert!(%Run{
      character_id: @id,
      status: "closed",
      plan: %{"type_name" => "Tritanium", "quantity" => 1_000, "tvs" => 92},
      predicted_profit: predicted,
      stages: %{},
      started_at: DateTime.add(now, -3600, :second),
      closed_at: now
    })
  end

  test "el primer viaje reconciliado logra hitos, avisa una sola vez y arma el registro" do
    run = closed_run(150_000_000.0)
    Tracking.put_result(run, %{profit: 150_000_000.0})

    assert_receive {:alert, %{title: "Hito logrado", body: "Primer contrato completado"}}
    assert_receive {:alert, %{body: "Primer contrato de rango S"}}
    assert_receive {:alert, %{body: "Recompensa acumulada de 100M"}}

    log = Tracking.hunter_log(@id)
    assert log.all.contracts == 1
    assert log.all.reward == 150_000_000.0
    assert log.all.accuracy == 1.0
    assert log.streak == 1

    # Un segundo resultado del mismo viaje no repite los hitos ya logrados.
    Tracking.put_result(run, %{profit: 150_000_000.0})
    refute_receive {:alert, %{title: "Hito logrado"}}, 100
  end

  test "los viajes sin reconciliar no cuentan" do
    closed_run(50_000_000.0)
    assert Tracking.hunter_log(@id).all.contracts == 0
  end
end
