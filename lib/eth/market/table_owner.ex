defmodule Eth.Market.TableOwner do
  @moduledoc """
  Dueño estable de las tablas ETS de órdenes y del catálogo de snapshots (RF-1.5).

  Cada ciclo de descarga construye una tabla nueva y la cede a este proceso con
  `:ets.give_away/3` (sin copiar datos). Al recibirla, el catálogo apunta a la nueva
  generación de forma atómica y la anterior se borra después de un período de gracia,
  para no invalidar lecturas en curso. Si un poller se cae, sus datos publicados siguen
  disponibles (RNF-2.1).

  Implementa: RF-1.5, RNF-2.1.
  """
  use GenServer

  alias Eth.GameRules

  @catalog :eth_market_catalog

  @type source :: {:region, pos_integer()}
  @type entry :: %{tid: :ets.tid(), generation: pos_integer(), meta: map()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Publica una tabla recién construida por el proceso llamador (que debe ser su dueño).
  Devuelve la generación asignada.
  """
  @spec publish(:ets.tid(), source(), map()) :: {:ok, pos_integer()}
  def publish(tid, source, meta) do
    ref = make_ref()
    owner = Process.whereis(__MODULE__)
    :ets.give_away(tid, owner, {:publish, source, meta, self(), ref})

    receive do
      {^ref, generation} -> {:ok, generation}
    after
      5_000 -> exit({:publish_timeout, source})
    end
  end

  @doc "Snapshot vigente de una fuente (`nil` si todavía no hay datos)."
  @spec current(source()) :: entry() | nil
  def current(source) do
    case :ets.lookup(@catalog, source) do
      [{^source, entry}] -> entry
      [] -> nil
    end
  end

  @doc "Todas las fuentes con snapshot vigente."
  @spec all() :: [{source(), entry()}]
  def all, do: :ets.tab2list(@catalog)

  @impl true
  def init(_opts) do
    :ets.new(@catalog, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_info({:"ETS-TRANSFER", tid, _from, {:publish, source, meta, caller, ref}}, state) do
    generation =
      case current(source) do
        nil ->
          1

        %{tid: old_tid, generation: gen} ->
          Process.send_after(self(), {:drop, old_tid}, GameRules.get(:snapshot_grace_ms))
          gen + 1
      end

    :ets.insert(@catalog, {source, %{tid: tid, generation: generation, meta: meta}})
    send(caller, {ref, generation})
    Phoenix.PubSub.broadcast(Eth.PubSub, topic(source), {:snapshot, source, generation, meta})
    {:noreply, state}
  end

  def handle_info({:drop, tid}, state) do
    if :ets.info(tid, :owner) == self(), do: :ets.delete(tid)
    {:noreply, state}
  end

  @doc "Tópico PubSub de una fuente (`market:region:<id>`)."
  @spec topic(source()) :: String.t()
  def topic({:region, id}), do: "market:region:#{id}"
end
