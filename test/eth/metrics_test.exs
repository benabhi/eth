defmodule Eth.MetricsTest do
  use ExUnit.Case, async: false

  alias Eth.Metrics

  setup do
    start_supervised!(Metrics)
    :ok
  end

  test "cuenta requests, errores, 304 y latencia de ESI en el minuto actual" do
    for {status, ms} <- [{200, 100}, {304, 50}, {503, 30}, {:transport_error, 20}] do
      :telemetry.execute([:eth, :esi, :request], %{duration_ms: ms}, %{
        path: "/x",
        status: status,
        group: nil,
        not_modified: status == 304
      })
    end

    s = Metrics.series()
    assert length(s.minutes) == 60
    assert List.last(s.requests) == 4
    assert List.last(s.errors) == 2
    assert List.last(s.not_modified) == 1
    assert List.last(s.latency_ms) == 50.0
    # Minutos sin datos: cero requests y sin latencia.
    assert hd(s.requests) == 0
    assert hd(s.latency_ms) == nil
  end

  test "promedia la duración de las evaluaciones y de las consultas del motor" do
    :telemetry.execute([:eth, :engine, :evaluate], %{duration_ms: 4_000}, %{})
    :telemetry.execute([:eth, :engine, :evaluate], %{duration_ms: 6_000}, %{})
    :telemetry.execute([:eth, :engine, :query], %{duration_us: 20_000}, %{rows: 1})

    s = Metrics.series()
    assert List.last(s.evaluate_ms) == 5_000.0
    assert List.last(s.query_ms) == 20.0
  end
end
