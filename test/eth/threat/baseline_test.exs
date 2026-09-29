defmodule Eth.Threat.BaselineTest do
  use Eth.DataCase, async: false

  alias Eth.EngineFixture
  alias Eth.Esi.Budget
  alias Eth.EsiStub
  alias Eth.Threat.{Baseline, BaselineModel}

  @moduletag :tmp_dir

  @jita 30_000_142
  @ahbazon 30_005_196

  setup %{tmp_dir: tmp_dir} do
    :ok = EngineFixture.load_sde(tmp_dir)
    :ok
  end

  describe "modelo (RF-3.4, RF-3.7)" do
    test "λ por franja con suficientes días; si no, promedio del sistema; mínimo 0,05" do
      # 7 días muestreados a las 18 UTC y 1 a las 3 UTC.
      samples = %{18 => 7, 3 => 1}

      activity = %{
        @ahbazon => %{by_hour: %{18 => 28, 3 => 4}, kills: 32, ship_kills: 20, jumps: 950}
      }

      %{@ahbazon => entry} = BaselineModel.compute(activity, samples, 10)
      # 28 kills en 7 días a las 18 → 4 por hora → 1 por ventana de 15 min.
      assert elem(entry.lambda, 18) == 1.0
      # Franja con 1 día: promedio general (32 kills / 8 horas / 4).
      assert elem(entry.lambda, 3) == 1.0
      # Riesgo base: 20 / (950 + 50).
      assert_in_delta entry.base_risk, 0.02, 1.0e-12

      quiet = BaselineModel.quiet(@jita, samples, 10)
      assert elem(quiet.lambda, 18) == 0.05
      assert quiet.base_risk == 0.0
    end

    test "sin muestras usa el prior por banda; el riesgo base tiene tope" do
      quiet = BaselineModel.quiet(@ahbazon, %{}, 0)
      assert elem(quiet.lambda, 0) == 0.2
      assert quiet.base_risk == 0.01

      busy = %{@jita => %{by_hour: %{}, kills: 0, ship_kills: 10_000, jumps: 1}}
      assert %{@jita => %{base_risk: 0.2}} = BaselineModel.compute(busy, %{}, 5)
    end
  end

  describe "proceso" do
    setup do
      Req.Test.set_req_test_to_shared()
      on_exit(&Req.Test.set_req_test_to_private/0)
      :ets.delete_all_objects(:eth_esi_budget)
      Budget.resume_all()
      start_supervised!({Task.Supervisor, name: Eth.Threat.TaskSupervisor})
      :ok
    end

    test "descarga kills y saltos, los guarda por hora y publica la línea base" do
      hour = ~U[2026-09-29 10:00:00Z]

      Req.Test.stub(Eth.Esi.Client, fn conn ->
        body =
          case conn.request_path do
            "/universe/system_kills" ->
              [%{"system_id" => @ahbazon, "ship_kills" => 4, "pod_kills" => 2, "npc_kills" => 9}]

            "/universe/system_jumps" ->
              [%{"system_id" => @ahbazon, "ship_jumps" => 150}]
          end

        EsiStub.respond(conn, 200, body,
          last_modified: DateTime.add(hour, 1_800, :second),
          expires: DateTime.add(DateTime.utc_now(), 3_600, :second),
          etag: ~s("b")
        )
      end)

      start_supervised!(Baseline)
      wait_until(fn -> Baseline.meta().jump_hours == 1 and Baseline.meta().kill_hours == 1 end)

      assert [%{ship_kills: 4, pod_kills: 2, jumps: 150}] =
               Repo.all(
                 from a in "system_activity_hourly",
                   where: a.solar_system_id == ^@ahbazon and a.hour == type(^hour, :utc_datetime),
                   select: %{ship_kills: a.ship_kills, pod_kills: a.pod_kills, jumps: a.jumps}
               )

      # Una sola hora muestreada (< 7 días): λ = 6 kills / 1 hora / 4 en todas las franjas.
      assert Baseline.lambda(@ahbazon, ~U[2026-09-29 18:00:00Z]) == 1.5
      assert_in_delta Baseline.base_risk(@ahbazon), 4 / 200, 1.0e-12
      # Sistema sin actividad en una hora muestreada: 0 kills → λ mínima, riesgo 0.
      assert Baseline.lambda(@jita, ~U[2026-09-29 18:00:00Z]) == 0.05
      assert Baseline.base_risk(@jita) == 0.0
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
