defmodule Eth.Esi.ServerStatusTest do
  # Modifica la configuración global de reglas: no async.
  use ExUnit.Case, async: false

  alias Eth.Esi.ServerStatus

  setup do
    original = Application.get_env(:eth, Eth.GameRules)
    rules = Keyword.put(original, :downtime_window_utc, {~T[10:59:00], ~T[11:15:00]})
    Application.put_env(:eth, Eth.GameRules, rules)
    on_exit(fn -> Application.put_env(:eth, Eth.GameRules, original) end)
  end

  test "detecta la ventana de downtime" do
    refute ServerStatus.in_window?(~U[2026-09-29 10:58:59Z])
    assert ServerStatus.in_window?(~U[2026-09-29 10:59:00Z])
    assert ServerStatus.in_window?(~U[2026-09-29 11:14:59Z])
    refute ServerStatus.in_window?(~U[2026-09-29 11:15:00Z])
  end

  test "fin de la ventana y próximo downtime" do
    assert ServerStatus.window_end(~U[2026-09-29 11:00:00Z]) == ~U[2026-09-29 11:15:00Z]
    assert ServerStatus.window_end(~U[2026-09-29 12:00:00Z]) == ~U[2026-09-30 11:15:00Z]
    assert ServerStatus.next_downtime(~U[2026-09-29 08:00:00Z]) == ~U[2026-09-29 10:59:00Z]
    assert ServerStatus.next_downtime(~U[2026-09-29 12:00:00Z]) == ~U[2026-09-30 10:59:00Z]
  end
end
