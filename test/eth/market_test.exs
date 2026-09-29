defmodule Eth.MarketTest do
  use ExUnit.Case, async: true

  alias Eth.Market

  @now ~U[2026-09-29 12:00:00Z]

  test "fresco mientras no venció Expires (más el margen de descarga)" do
    lm = ~U[2026-09-29 11:55:30Z]
    assert Market.freshness(lm, ~U[2026-09-29 12:00:30Z], @now) == :fresh
    assert Market.freshness(lm, ~U[2026-09-29 11:59:00Z], @now) == :fresh
  end

  test "se degrada por antigüedad una vez vencido" do
    expired = ~U[2026-09-29 11:30:00Z]
    assert Market.freshness(~U[2026-09-29 11:50:00Z], expired, @now) == :degraded
    assert Market.freshness(~U[2026-09-29 11:40:00Z], expired, @now) == :stale
    assert Market.freshness(~U[2026-09-29 11:00:00Z], expired, @now) == :excluded
  end

  test "sin datos" do
    assert Market.freshness(nil, nil, @now) == :none
  end

  test "sin mercado corriendo no hay estados" do
    assert Market.region_statuses() == []
  end
end
