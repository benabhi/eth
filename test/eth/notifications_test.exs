defmodule Eth.NotificationsTest do
  use Eth.DataCase, async: false

  alias Eth.Engine.Coordinator
  alias Eth.EngineFixture, as: F
  alias Eth.Market.TableOwner
  alias Eth.Notifications
  alias Eth.Notifications.Dispatcher

  @moduletag :tmp_dir
  @moduletag :capture_log

  @tritanium 34

  setup %{tmp_dir: tmp_dir} do
    :ok = F.load_sde(tmp_dir)
    start_supervised!(TableOwner)
    start_supervised!({Task.Supervisor, name: Eth.Engine.TaskSupervisor})
    start_supervised!(Coordinator)
    start_supervised!(Dispatcher)
    Phoenix.PubSub.subscribe(Eth.PubSub, Notifications.topic())
    Phoenix.PubSub.subscribe(Eth.PubSub, Coordinator.topic())
    :ok
  end

  test "publica una alerta y no repite la misma clave dentro del enfriamiento" do
    Notifications.notify(%{key: "k1", title: "Hola"})
    assert_receive {:alert, %{key: "k1", title: "Hola", level: :info}}

    Notifications.notify(%{key: "k1", title: "Hola otra vez"})
    refute_receive {:alert, %{key: "k1"}}, 100

    Notifications.notify(%{key: "k2", title: "Otra"})
    assert_receive {:alert, %{key: "k2"}}
  end

  test "regla por defecto apagada; se guarda y valida" do
    assert %{enabled: false, min_tvs: 75} = Notifications.rule()
    assert :ok = Notifications.put_rule(%{enabled: true, min_tvs: 1, min_profit: 1_000})
    assert %{enabled: true, min_tvs: 1} = Notifications.rule()

    assert {:error, :invalid_value} =
             Notifications.put_rule(%{enabled: true, min_tvs: 150, min_profit: 1})
  end

  test "avisa contratos nuevos que cumplen la regla, sin avisar los de la primera evaluación" do
    :ok = Notifications.put_rule(%{enabled: true, min_tvs: 0, min_profit: 1_000})

    # Primera evaluación: solo siembra.
    F.publish_orders([
      {:sell, @tritanium, 4.0, 10_000_000, F.jita_44(), F.jita(), []},
      {:buy, @tritanium, 5.0, 10_000_000, F.perimeter_station(), F.perimeter(), []}
    ])

    assert_receive {:opportunities_updated, %{version: 1}}, 5_000
    refute_receive {:alert, _}, 300

    # Aparece otro contrato en highsec (la regla usa la ruta Segura del modo invitado).
    F.publish_orders([
      {:sell, @tritanium, 4.0, 10_000_000, F.jita_44(), F.jita(), []},
      {:buy, @tritanium, 5.0, 10_000_000, F.perimeter_station(), F.perimeter(), []},
      {:sell, 657, 1_000_000.0, 5, F.jita_44(), F.jita(), []},
      {:buy, 657, 1_300_000.0, 5, F.perimeter_station(), F.perimeter(), []}
    ])

    assert_receive {:opportunities_updated, %{version: 2}}, 5_000
    assert_receive {:alert, %{title: "Nuevo contrato: Iteron Mark V" <> _, body: body}}, 2_000
    assert body =~ "Perimeter"
    # El Tritanium ya estaba: no vuelve a avisarse.
    refute_receive {:alert, %{title: "Nuevo contrato: Tritanium" <> _}}, 300
  end

  test "avisa cuando un personaje debe volver a loguear" do
    {:ok, c} =
      Eth.Characters.upsert_login(%{
        character_id: 2_112_345_678,
        name: "Hernan Test",
        owner_hash: "h",
        scopes: [],
        refresh_token: "r"
      })

    stop_supervised!(Dispatcher)
    start_supervised!(Dispatcher)

    Phoenix.PubSub.broadcast(
      Eth.PubSub,
      Eth.Characters.Session.topic(c.id),
      {:character, c.id, :relogin, %{name: "Hernan Test"}}
    )

    assert_receive {:alert,
                    %{key: "relogin:2112345678", level: :error, title: "Hernan Test: " <> _}}
  end
end
