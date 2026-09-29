defmodule Eth.Esi.HttpDateTest do
  use ExUnit.Case, async: true

  alias Eth.Esi.HttpDate

  test "interpreta el formato de ESI" do
    assert HttpDate.parse("Tue, 29 Sep 2026 00:02:18 GMT") == ~U[2026-09-29 00:02:18Z]
  end

  test "devuelve nil ante valores ausentes o inválidos" do
    assert HttpDate.parse(nil) == nil
    assert HttpDate.parse("mañana") == nil
    assert HttpDate.parse("Tue, 31 Feb 2026 00:00:00 GMT") == nil
  end
end
