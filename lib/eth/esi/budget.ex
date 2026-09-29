defmodule Eth.Esi.Budget do
  @moduledoc """
  Presupuesto de ESI: rate limit por grupo (token bucket, `X-Ratelimit-*`) y error limit
  legado (`X-ESI-Error-Limit-*`), con pausas automáticas (RF-1.7).

  - Cada respuesta actualiza el estado del grupo (y del personaje en rutas autenticadas).
  - `429` pausa solo ese grupo durante `Retry-After`.
  - `420`, o un error limit restante ≤ `:error_limit_pause_at`, pausa **todo** ESI hasta
    el reset.
  - La pausa global manual (kill switch, RF-8.8) usa el mismo mecanismo.

  El estado vive en una tabla ETS pública (lecturas concurrentes desde cualquier proceso);
  este proceso solo es su dueño.

  Implementa: RF-1.7, RNF-2.3.
  """
  use GenServer

  alias Eth.Clock
  alias Eth.Esi.Response
  alias Eth.GameRules

  @table :eth_esi_budget

  @type group_key :: {String.t(), pos_integer() | nil}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Verifica si se puede hacer un request al grupo indicado (o a cualquiera si `nil`).
  """
  @spec check(String.t() | nil, pos_integer() | nil) ::
          :ok | {:error, {:paused, DateTime.t()}} | {:error, {:rate_limited, DateTime.t()}}
  def check(group \\ nil, character_id \\ nil) do
    now = Clock.utc_now()

    case active_until(:global_pause, now) do
      %DateTime{} = until -> {:error, {:paused, until}}
      nil -> check_group(group, character_id, now)
    end
  end

  defp check_group(nil, _character_id, _now), do: :ok

  defp check_group(group, character_id, now) do
    case active_until({:group_pause, {group, character_id}}, now) do
      %DateTime{} = until -> {:error, {:rate_limited, until}}
      nil -> :ok
    end
  end

  @doc "Registra una respuesta y aplica las pausas que correspondan."
  @spec record(Response.t(), pos_integer() | nil) :: :ok
  def record(%Response{} = resp, character_id \\ nil) do
    now = Clock.utc_now()

    if rl = resp.rate_limit do
      :ets.insert(@table, {{:group, {rl.group, character_id}}, Map.put(rl, :at, now)})

      if resp.status == 429 do
        until = DateTime.add(now, resp.retry_after_s || 60, :second)
        :ets.insert(@table, {{:group_pause, {rl.group, character_id}}, until})
      end
    end

    if el = resp.error_limit do
      :ets.insert(@table, {:error_limit, Map.put(el, :at, now)})

      if el.remain <= GameRules.get(:error_limit_pause_at) do
        pause_all(DateTime.add(now, max(el.reset_s, 1), :second), :error_limit)
      end
    end

    if resp.status == 420 do
      reset_s = (resp.error_limit && resp.error_limit.reset_s) || 60
      pause_all(DateTime.add(now, max(reset_s, 1), :second), :error_limited)
    end

    :ok
  end

  @doc "Pausa global de ESI hasta `until` (automática o manual)."
  @spec pause_all(DateTime.t(), atom()) :: :ok
  def pause_all(%DateTime{} = until, reason \\ :manual) do
    :ets.insert(@table, {:global_pause, until})
    :ets.insert(@table, {:global_pause_reason, reason})
    Phoenix.PubSub.broadcast(Eth.PubSub, "market:status", {:esi_paused, until, reason})
    :ok
  end

  @doc "Levanta la pausa global."
  @spec resume_all() :: :ok
  def resume_all do
    :ets.delete(@table, :global_pause)
    :ets.delete(@table, :global_pause_reason)
    Phoenix.PubSub.broadcast(Eth.PubSub, "market:status", :esi_resumed)
    :ok
  end

  @doc "Estado conocido de un grupo (`nil` si ESI aún no informó límites para él)."
  @spec group(String.t(), pos_integer() | nil) :: map() | nil
  def group(group, character_id \\ nil) do
    case :ets.lookup(@table, {:group, {group, character_id}}) do
      [{_, state}] -> state
      [] -> nil
    end
  end

  @doc "Fracción restante del presupuesto de un grupo (1.0 si no hay datos)."
  @spec remaining_ratio(String.t(), pos_integer() | nil) :: float()
  def remaining_ratio(group, character_id \\ nil) do
    case group(group, character_id) do
      %{limit: limit, remaining: remaining} when limit > 0 -> remaining / limit
      _ -> 1.0
    end
  end

  @doc "Instantánea completa para el Centro de control."
  @spec snapshot() :: map()
  def snapshot do
    now = Clock.utc_now()
    entries = :ets.tab2list(@table)

    %{
      groups:
        for({{:group, {name, char}}, state} <- entries, into: %{}, do: {{name, char}, state}),
      error_limit: Enum.find_value(entries, fn {k, v} -> k == :error_limit && v end),
      paused_until: active_until(:global_pause, now),
      pause_reason: Enum.find_value(entries, fn {k, v} -> k == :global_pause_reason && v end)
    }
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    {:ok, nil}
  end

  defp active_until(key, now) do
    case :ets.lookup(@table, key) do
      [{_, until}] -> if DateTime.compare(until, now) == :gt, do: until
      [] -> nil
    end
  end
end
