defmodule Eth.GameRules.Overrides do
  @moduledoc """
  Dueño estable de la tabla ETS de overrides de las reglas del juego (RF-9.4). Al
  arrancar carga los overrides guardados en los ajustes del operador; `reload/0` los
  vuelve a publicar después de un cambio desde Ajustes.

  También publica los ajustes del radar (α del modo Evasiva y sistemas a evitar, RF-9.5).

  Implementa: RF-9.4, RF-9.5, RNF-15.2.
  """
  use GenServer

  alias Eth.{Accounts, GameRules}
  alias Eth.GameRules.Tunable

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Vuelve a cargar los overrides desde la base (sincrónico)."
  @spec reload() :: :ok
  def reload do
    if GenServer.whereis(__MODULE__), do: GenServer.call(__MODULE__, :reload), else: :ok
  end

  # La carga es sincrónica en `init`: cuando arrancan los procesos siguientes (el motor),
  # los overrides ya están publicados. Es una sola consulta a la base.
  @impl true
  def init(_opts) do
    :ets.new(GameRules.overrides_table(), [:named_table, :protected, read_concurrency: true])
    load()
    {:ok, %{}}
  end

  @impl true
  def handle_call(:reload, _from, state) do
    load()
    {:reply, :ok, state}
  end

  defp load do
    # Los parámetros del motor (RF-9.5) se publican como el valor completo de su clave.
    overrides =
      Accounts.game_rule_overrides()
      |> Map.merge(Accounts.radar_overrides())
      |> Map.merge(Tunable.merge(Accounts.engine_overrides()))

    table = GameRules.overrides_table()
    :ets.delete_all_objects(table)
    :ets.insert(table, Map.to_list(overrides))
    :telemetry.execute([:eth, :game_rules, :overrides], %{count: map_size(overrides)}, %{})
  end
end
