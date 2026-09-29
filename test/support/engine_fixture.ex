defmodule Eth.EngineFixture do
  @moduledoc """
  Escenario de mercado para tests del motor, sin red:

  - carga el mini SDE (`Eth.SdeFixture`: Jita — Perimeter — Ahbazon) en `persistent_term`;
  - publica tablas de órdenes sintéticas en `Eth.Market.TableOwner`.
  """

  alias Eth.Market.{Order, TableOwner}
  alias Eth.Routing.Graph
  alias Eth.Sde.Processor
  alias Eth.SdeFixture

  @jita 30_000_142
  @perimeter 30_000_144
  @ahbazon 30_005_196
  @jita_44 60_003_760

  def jita, do: @jita
  def perimeter, do: @perimeter
  def ahbazon, do: @ahbazon
  def jita_44, do: @jita_44
  # Estaciones sin datos en el mini SDE: se tratan como estructuras.
  def perimeter_station, do: 1_000_000_000_001
  @doc "Estación NPC en Perimeter (1 salto de Jita)."
  def perimeter_npc, do: 60_000_004
  def ahbazon_station, do: 1_000_000_000_002

  @doc "Publica el mini SDE y su grafo en persistent_term (se borra al terminar el test)."
  def load_sde(tmp_dir) do
    dir = Path.join(tmp_dir, "sde")
    SdeFixture.write(dir)
    data = Processor.process(dir, fn _ids -> %{} end)

    graph =
      Graph.build(data.systems,
        root: @jita,
        excluded_region_ids: [10_000_070],
        highsec_min: 0.45
      )

    :persistent_term.put({Eth.Sde, :data}, data)
    :persistent_term.put({Eth.Routing, :graph}, graph)

    ExUnit.Callbacks.on_exit(fn ->
      :persistent_term.erase({Eth.Sde, :data})
      :persistent_term.erase({Eth.Routing, :graph})
    end)

    :ok
  end

  @doc """
  Publica una tabla de órdenes para The Forge. Cada orden:
  `{:sell | :buy, type_id, price, volume, location_id, system_id, opts}` con opts
  `:range` y `:min_volume`.
  """
  def publish_orders(orders, last_modified \\ DateTime.utc_now()) do
    tid = :ets.new(:eth_orders, [:ordered_set, :public, read_concurrency: true])

    rows =
      orders
      |> Enum.with_index(1)
      |> Enum.map(fn {{side, type_id, price, volume, loc, sys, opts}, id} ->
        Order.to_row(
          %{
            "order_id" => id,
            "type_id" => type_id,
            "is_buy_order" => side == :buy,
            "price" => price,
            "location_id" => loc,
            "system_id" => sys,
            "volume_remain" => volume,
            "volume_total" => volume,
            "min_volume" => Keyword.get(opts, :min_volume, 1),
            "range" => Keyword.get(opts, :range, "station"),
            "issued" => "2026-09-28T12:00:00Z",
            "duration" => 90
          },
          1
        )
      end)

    :ets.insert(tid, rows)

    meta = %{
      last_modified: DateTime.truncate(last_modified, :second),
      expires: DateTime.add(last_modified, 300, :second),
      pages: 1,
      page_etags: %{},
      orders: length(rows)
    }

    {:ok, generation} = TableOwner.publish(tid, {:region, 10_000_002}, meta)
    generation
  end
end
