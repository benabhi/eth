defmodule Eth.CharactersTest do
  use Eth.DataCase, async: false

  alias Eth.Characters
  alias Eth.Characters.{Session, Sessions}
  alias Eth.Esi.Budget
  alias Eth.EsiStub
  alias Eth.Sso.Jwt
  alias Eth.SsoFixture, as: F

  @moduletag :capture_log

  @id F.character_id()

  defp login(attrs \\ %{}) do
    Map.merge(
      %{
        character_id: @id,
        name: "Hernan Test",
        owner_hash: "owner-hash-1",
        scopes: Eth.Sso.scopes(),
        access_token: "access-1",
        refresh_token: "refresh-1",
        expires_at: DateTime.add(DateTime.utc_now(), 1199, :second)
      },
      attrs
    )
  end

  describe "personajes y perfiles de nave" do
    test "upsert del login y rotación del refresh token" do
      assert {:ok, c} = Characters.upsert_login(login())
      assert c.token_status == "ok"

      :ok = Characters.update_refresh_token(@id, "refresh-2")
      assert Characters.get(@id).refresh_token == "refresh-2"

      :ok = Characters.mark_relogin(@id)
      assert Characters.get(@id).token_status == "relogin"

      # Un login nuevo vuelve a dejarlo operativo.
      {:ok, c} = Characters.upsert_login(login(%{refresh_token: "refresh-3"}))
      assert c.token_status == "ok"
      assert Characters.get(@id).refresh_token == "refresh-3"
    end

    test "perfil por nave concreta con fallback por casco" do
      assert {:ok, _} =
               Characters.save_ship_profile(
                 1_001,
                 657,
                 %{cargo_m3: 38_500, evasion_class: "industrial"},
                 apply_to_hull: true
               )

      # Otra Iteron sin perfil propio usa el del casco.
      assert %{cargo_m3: 38_500.0, ship_item_id: nil} = Characters.ship_profile(2_002, 657)

      assert {:ok, _} =
               Characters.save_ship_profile(2_002, 657, %{
                 cargo_m3: 5_800,
                 evasion_class: "industrial"
               })

      assert %{cargo_m3: 5_800.0} = Characters.ship_profile(2_002, 657)
      assert Characters.ship_profile(3_003, 999) == nil

      assert {:error, changeset} =
               Characters.save_ship_profile(4_004, 657, %{cargo_m3: -1, evasion_class: "nave"})

      assert %{cargo_m3: [_], evasion_class: [_]} = errors_on(changeset)
    end

    test "olvidar revoca el token y borra el personaje" do
      keys = F.keys()
      Jwt.clear_cache()
      F.stub(keys, %{})
      {:ok, _} = Characters.upsert_login(login())

      assert :ok = Characters.forget(@id)
      assert Characters.get(@id) == nil
    end
  end

  describe "sesión del personaje" do
    setup do
      Req.Test.set_req_test_to_shared()
      on_exit(&Req.Test.set_req_test_to_private/0)
      Budget.resume_all()
      start_supervised!(Characters.Supervisor)
      Phoenix.PubSub.subscribe(Eth.PubSub, Session.topic(@id))
      {:ok, _} = Characters.upsert_login(login())
      :ok
    end

    defp stub_esi do
      Req.Test.stub(Eth.Esi.Client, fn conn ->
        ["Bearer access-" <> _] = Plug.Conn.get_req_header(conn, "authorization")

        ["", "characters", id, resource] = String.split(conn.request_path, "/")
        assert id == Integer.to_string(@id)

        if resource == "assets",
          do: assets_page(conn),
          else: character_resource(conn, resource)
      end)
    end

    # Assets en dos páginas: módulos montados en la nave 1001 (y cosas que no lo son).
    defp assets_page(conn) do
      conn = Plug.Conn.fetch_query_params(conn)

      items =
        case conn.query_params["page"] do
          "1" ->
            [
              asset(1, 1_319, 1_001, "LoSlot0", "item"),
              asset(2, 34, 1_001, "Cargo", "item"),
              asset(3, 1_319, 60_003_760, "Hangar", "station")
            ]

          "2" ->
            [
              asset(4, 1_319, 1_001, "LoSlot1", "item"),
              asset(5, 31_119, 1_001, "RigSlot0", "item")
            ]
        end

      EsiStub.respond(conn, 200, items,
        pages: 2,
        expires: DateTime.add(DateTime.utc_now(), 3600, :second)
      )
    end

    defp asset(item_id, type_id, location_id, flag, location_type) do
      %{
        "item_id" => item_id,
        "type_id" => type_id,
        "location_id" => location_id,
        "location_flag" => flag,
        "location_type" => location_type,
        "quantity" => 1,
        "is_singleton" => true
      }
    end

    defp character_resource(conn, resource) do
      body =
        case resource do
          "online" ->
            %{"online" => true}

          "location" ->
            %{"solar_system_id" => 30_000_142, "station_id" => 60_003_760}

          "ship" ->
            %{"ship_type_id" => 657, "ship_item_id" => 1_001, "ship_name" => "Carguero"}

          "wallet" ->
            5_020_000_000.55

          "skills" ->
            %{"skills" => [%{"skill_id" => 16_622, "active_skill_level" => 5}]}

          "standings" ->
            [%{"from_id" => 1_000_035, "from_type" => "npc_corp", "standing" => 2.5}]

          "orders" ->
            [
              %{
                "order_id" => 6_001,
                "type_id" => 34,
                "region_id" => 10_000_002,
                "location_id" => 60_003_760,
                "is_buy_order" => false,
                "price" => 5.0,
                "volume_total" => 1_000,
                "volume_remain" => 800,
                "range" => "region",
                "issued" => "2026-09-28T12:00:00Z",
                "duration" => 90,
                "is_corporation" => false
              },
              %{
                "order_id" => 6_002,
                "type_id" => 34,
                "region_id" => 10_000_002,
                "location_id" => 60_003_760,
                "is_buy_order" => true,
                "price" => 4.0,
                "escrow" => 4_000.0,
                "min_volume" => 1,
                "volume_total" => 1_000,
                "volume_remain" => 1_000,
                "range" => "station",
                "issued" => "2026-09-28T12:00:00Z",
                "duration" => 90,
                "is_corporation" => false
              },
              %{
                "order_id" => 6_003,
                "type_id" => 34,
                "region_id" => 10_000_002,
                "location_id" => 60_003_760,
                "price" => 9.0,
                "volume_total" => 1,
                "volume_remain" => 1,
                "range" => "region",
                "duration" => 90,
                "issued" => "2026-09-28T12:00:00Z",
                "is_corporation" => true
              }
            ]
        end

      EsiStub.respond(conn, 200, body, expires: DateTime.add(DateTime.utc_now(), 5, :second))
    end

    defp await_context(check, attempts \\ 50) do
      context = Sessions.context(@id)

      cond do
        context && check.(context) ->
          context

        attempts == 0 ->
          flunk("el contexto nunca cumplió la condición: #{inspect(context)}")

        true ->
          assert_receive {:character, @id, _event, _public}, 1_000
          await_context(check, attempts - 1)
      end
    end

    test "con token vigente consulta ESI y publica el contexto" do
      stub_esi()
      :ok = Sessions.start(@id, login())

      context = await_context(&(map_size(&1.context) == 8))
      assert context.status == :ok
      assert context.context.location.station_id == 60_003_760
      assert context.context.ship.ship_name == "Carguero"
      assert context.context.wallet == 5_020_000_000.55
      assert context.context.skills[16_622] == 5
      assert context.context.standings[1_000_035] == 2.5
      # De los assets (dos páginas) quedan solo los módulos montados, por nave.
      assert context.context.assets == %{1_001 => [1_319, 1_319, 31_119]}
      # Órdenes personales (la de corporación se descarta), con su lado y escrow.
      assert [%{order_id: 6_001, buy: false}, %{order_id: 6_002, buy: true, escrow: 4_000.0}] =
               context.context.orders

      assert {:ok, "access-1"} = Sessions.token(@id)
    end

    test "sin access token renueva con el refresh token y persiste el rotado" do
      keys = F.keys()
      Jwt.clear_cache()
      F.stub(keys, F.token_body("access-2", "refresh-rotado"))
      stub_esi()

      :ok = Sessions.start(@id)
      await_context(&(&1.status == :ok))

      assert {:ok, "access-2"} = Sessions.token(@id)
      assert Characters.get(@id).refresh_token == "refresh-rotado"
    end

    test "invalid_grant deja al personaje pidiendo re-login" do
      keys = F.keys()
      Jwt.clear_cache()
      F.stub(keys, {400, %{"error" => "invalid_grant"}})

      :ok = Sessions.start(@id)
      assert_receive {:character, @id, :relogin, %{status: :relogin}}, 2_000
      assert Characters.get(@id).token_status == "relogin"
      assert {:error, :relogin} = Sessions.token(@id)
    end
  end
end
