defmodule EthWeb.FormatTest do
  use ExUnit.Case, async: true

  alias EthWeb.Format

  test "compact abrevia con 3 cifras significativas" do
    assert Format.compact(nil) == "—"
    assert Format.compact(999) == "999"
    assert Format.compact(1_234) == "1.23k"
    assert Format.compact(404_647) == "405k"
    assert Format.compact(64_000_000) == "64.0M"
    assert Format.compact(5_020_000_000) == "5.02B"
    assert Format.compact(1.5e12) == "1.50T"
  end

  test "integer usa coma de miles (estilo EVE)" do
    assert Format.integer(404_647) == "404,647"
    assert Format.integer(1_000) == "1,000"
    assert Format.integer(12) == "12"
    assert Format.integer(-1_234_567) == "-1,234,567"
  end

  test "bytes" do
    assert Format.bytes(77_700_000) == "74.1 MB"
    assert Format.bytes(2_147_483_648) == "2.0 GB"
  end

  test "countdown, duration y ago" do
    now = ~U[2026-09-29 12:00:00Z]
    assert Format.countdown(~U[2026-09-29 12:01:42Z], now) == "01:42"
    assert Format.countdown(~U[2026-09-29 11:00:00Z], now) == "00:00"
    assert Format.duration(5 * 3600 + 12 * 60 + 3) == "5:12:03"
    assert Format.ago(~U[2026-09-29 11:59:56Z], now) == "hace 4 s"
    assert Format.ago(~U[2026-09-29 11:51:00Z], now) == "hace 9 min"
    assert Format.ago(~U[2026-09-29 10:00:00Z], now) == "hace 2 h"
    assert Format.eve_time(now) == "12:00:00"
  end
end
