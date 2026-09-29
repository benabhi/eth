defmodule Eth.Characters.OrderWatch do
  @moduledoc """
  Vigila las órdenes propias de los personajes con sesión (RF-4.17) y avisa cuando una
  deja de ser la primera (RF-10.5).

  - Recalcula el estado con cada evaluación del motor (`engine:opportunities`, el libro
    cambió) y con cada lectura nueva de órdenes de un personaje (`character:<id>`).
  - Solo avisa las **transiciones** de primera a superada: la primera lectura de cada
    personaje siembra el estado sin avisar, y una orden que sigue superada no vuelve a
    sonar (además, el despachador aplica su enfriamiento por clave).
  - Emite `[:eth, :characters, :orders]` con la cantidad de órdenes y de superadas.

  El cálculo lee tablas ETS (sin HTTP) y es proporcional a la cantidad de órdenes.

  Implementa: RF-4.17, RF-10.5.
  """
  use GenServer

  alias Eth.{Characters, Engine, Notifications}
  alias Eth.Characters.{Pilot, Session, Sessions}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc false
  # Transiciones que merecen alerta: órdenes que antes estaban primeras y ahora no.
  @spec newly_outbid(%{pos_integer() => atom()}, [map()]) :: [map()]
  def newly_outbid(previous, rows) do
    Enum.filter(rows, &(&1.status == :outbid and Map.get(previous, &1.order_id) == :best))
  end

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(Eth.PubSub, Engine.topic())
    for c <- Characters.list(), do: Phoenix.PubSub.subscribe(Eth.PubSub, Session.topic(c.id))
    {:ok, %{statuses: %{}}}
  end

  @impl true
  def handle_info({:opportunities_updated, _meta}, state), do: {:noreply, check_all(state)}

  def handle_info({:character, id, {:updated, :orders}, public}, state),
    do: {:noreply, check(state, id, public)}

  def handle_info(_msg, state), do: {:noreply, state}

  defp check_all(state) do
    Enum.reduce(Sessions.list(), state, &check(&2, &1.id, &1))
  end

  defp check(state, id, public) do
    with %{} = character <- Characters.get(id),
         %{orders: orders} = pilot when is_list(orders) <- Pilot.build(public, character) do
      rows = Engine.own_orders(orders, Pilot.station_overrides(pilot))
      previous = Map.get(state.statuses, id)

      if previous, do: Enum.each(newly_outbid(previous, rows), &alert(pilot, &1))

      :telemetry.execute(
        [:eth, :characters, :orders],
        %{count: length(rows), outbid: Enum.count(rows, &(&1.status == :outbid))},
        %{character_id: id}
      )

      %{state | statuses: Map.put(state.statuses, id, Map.new(rows, &{&1.order_id, &1.status}))}
    else
      _ -> state
    end
  end

  defp alert(pilot, row) do
    side = if row.buy, do: "compra", else: "venta"

    Notifications.notify(%{
      key: "outbid:#{row.order_id}",
      level: :warning,
      title: "#{pilot.name}: superaron tu orden de #{side} de #{row.type_name}",
      body: "Precio sugerido #{row.suggested_price} ISK (tu precio: #{row.price})",
      url: "/station"
    })
  end
end
