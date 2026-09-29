defmodule Eth.EventsTest do
  use Eth.DataCase, async: true

  alias Eth.Events
  alias Eth.Events.Event

  # Los eventos también se escriben en el log de la aplicación.
  @moduletag :capture_log

  test "emit persiste y publica el evento" do
    Phoenix.PubSub.subscribe(Eth.PubSub, Events.topic())

    event = Events.emit(:warning, "The Forge", "HTTP 502 · reintento en 30 s", %{attempt: 3})

    assert %Event{id: id, level: "warning", source: "The Forge"} = event
    assert is_integer(id)
    assert_receive {:system_event, %Event{id: ^id}}
  end

  test "recent ordena del más nuevo al más viejo y filtra" do
    Events.emit(:info, "Motor", "ciclo 1")
    Events.emit(:error, "Domain", "timeout")
    Events.emit(:action, "Usuario", "pausa de Domain")

    assert [%{message: "pausa de Domain"}, %{message: "timeout"}, %{message: "ciclo 1"}] =
             Events.recent(10)

    assert [%{message: "timeout"}] = Events.recent(10, level: "error")
    assert [%{message: "pausa de Domain"}] = Events.recent(10, search: "PAUSA")
  end

  test "prune borra solo lo que supera la retención de 7 días" do
    old = DateTime.add(DateTime.utc_now(), -8, :day)
    Repo.insert!(%Event{at: old, level: "info", source: "x", message: "viejo"})
    Events.emit(:info, "x", "nuevo")

    assert Events.prune() == 1
    assert [%{message: "nuevo"}] = Events.recent(10)
  end
end
