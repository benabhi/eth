defmodule Eth.Market.Fetcher do
  @moduledoc """
  Descarga un snapshot completo de órdenes de una región o de una estructura y lo publica
  (RF-1.4, RF-1.5, RF-1.6).

  1. Pide la página 1 y lee `X-Pages`; luego el resto con concurrencia acotada.
  2. Cada página se envía con el `ETag` de la generación vigente: un `304` se resuelve
     copiando esas filas de la tabla vigente (cuesta 1 token en lugar de 2).
  3. Exige que todas las páginas compartan `Last-Modified` y `X-Pages`. Las que quedaron
     de una generación anterior de la caché de ESI se vuelven a pedir (hasta
     `:page_retries` veces); si no se logra, el ciclo se descarta sin publicar nada.
  4. Publica la tabla nueva en `Eth.Market.TableOwner`.

  Se ejecuta dentro de una tarea supervisada: si falla, la tabla a medio construir
  muere con la tarea.

  Implementa: RF-1.4, RF-1.5, RF-1.6, RNF-3.3.
  """

  alias Eth.Esi
  alias Eth.Esi.Response
  alias Eth.GameRules
  alias Eth.Market.{Order, TableOwner}

  @type meta :: %{
          last_modified: DateTime.t(),
          expires: DateTime.t(),
          pages: pos_integer(),
          page_etags: %{pos_integer() => String.t()},
          orders: non_neg_integer(),
          sell_orders: non_neg_integer(),
          buy_orders: non_neg_integer(),
          bytes: non_neg_integer(),
          not_modified_pages: non_neg_integer(),
          duration_ms: non_neg_integer(),
          generation: pos_integer()
        }

  @type error ::
          {:paused, DateTime.t()}
          | {:rate_limited, DateTime.t()}
          | {:http, non_neg_integer()}
          | {:transport, term()}
          | :inconsistent

  @doc """
  Descarga y publica el snapshot de `region_id`. `notify` recibe
  `{:fetch_progress, region_id, done, total}` durante la descarga.
  """
  @spec fetch(pos_integer(), pid() | nil) :: {:ok, meta()} | {:error, error()}
  def fetch(region_id, notify \\ nil) do
    fetch_source(
      %{
        source: {:region, region_id},
        id: region_id,
        request: &Esi.market_orders(region_id, &1, &2),
        prepare: & &1
      },
      notify
    )
  end

  @doc """
  Descarga y publica el mercado de una estructura (RF-1.6) con el token de un personaje
  con acceso. Sus órdenes no traen `system_id`: se completa con el de la estructura.
  """
  @spec fetch_structure(pos_integer(), pos_integer(), pos_integer(), String.t()) ::
          {:ok, meta()} | {:error, error()}
  def fetch_structure(structure_id, system_id, character_id, token) do
    fetch_source(
      %{
        source: {:structure, structure_id},
        id: structure_id,
        request: &Esi.structure_orders(structure_id, &1, &2, character_id, token),
        prepare: &Map.put(&1, "system_id", system_id),
        meta: %{system_id: system_id, region_id: (Eth.Sde.system(system_id) || %{})[:region_id]}
      },
      nil
    )
  end

  defp fetch_source(ctx, notify) do
    started = System.monotonic_time(:millisecond)
    source = ctx.source
    previous = TableOwner.current(source)
    etags = (previous && previous.meta.page_etags) || %{}
    table = :ets.new(:eth_orders, [:ordered_set, :public, read_concurrency: true])

    with {:ok, first} <- fetch_page(ctx, 1, etags, table),
         total = first.pages,
         {:ok, rest} <- fetch_pages(ctx, 2..total//1, etags, table, notify),
         {:ok, pages} <- ensure_consistent(ctx, [first | rest], etags, table, 0) do
      copy_not_modified(pages, previous, table)
      meta = pages |> build_meta(table, started) |> Map.merge(Map.get(ctx, :meta, %{}))
      {:ok, generation} = TableOwner.publish(table, source, meta)
      {:ok, Map.put(meta, :generation, generation)}
    end
  end

  # Resultado por página: status, Last-Modified, Expires, total de páginas y ETag.
  defp fetch_page(ctx, page, etags, table) do
    case ctx.request.(page, Map.get(etags, page)) do
      {:ok, %Response{status: 304} = resp} ->
        {:ok, page_result(page, resp)}

      {:ok, %Response{} = resp} ->
        rows = Enum.map(resp.body, &Order.to_row(ctx.prepare.(&1), page))
        :ets.insert(table, rows)
        {:ok, page_result(page, resp)}

      {:error, {:http, %Response{status: status}}} ->
        {:error, {:http, status}}

      {:error, {:transport, exception}} ->
        {:error, {:transport, Exception.message(exception)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp page_result(page, %Response{} = resp) do
    %{
      page: page,
      status: resp.status,
      last_modified: resp.last_modified,
      expires: resp.expires,
      pages: resp.pages || 1,
      etag: resp.etag
    }
  end

  defp fetch_pages(ctx, pages, etags, table, notify) do
    total = Enum.count(pages) + 1

    pages
    |> Task.async_stream(&fetch_page(ctx, &1, etags, table),
      max_concurrency: GameRules.get(:pages_concurrency),
      timeout: :infinity,
      ordered: false
    )
    |> Enum.reduce_while({:ok, [], 1}, fn
      {:ok, {:ok, result}}, {:ok, acc, done} ->
        notify_progress(notify, ctx.id, done + 1, total)
        {:cont, {:ok, [result | acc], done + 1}}

      {:ok, {:error, reason}}, _acc ->
        {:halt, {:error, reason}}
    end)
    |> case do
      {:ok, results, _done} -> {:ok, results}
      error -> error
    end
  end

  defp notify_progress(nil, _region_id, _done, _total), do: :ok

  defp notify_progress(pid, region_id, done, total) do
    if rem(done, 10) == 0 or done == total do
      send(pid, {:fetch_progress, region_id, done, total})
    end

    :ok
  end

  # Todas las páginas deben venir del mismo snapshot de ESI: se toma el Last-Modified más
  # nuevo como referencia y se vuelven a pedir las que quedaron atrás.
  defp ensure_consistent(ctx, pages, etags, table, attempt) do
    target = pages |> Enum.map(& &1.last_modified) |> Enum.max(DateTime)
    total = hd(pages).pages

    {stale, fresh} =
      Enum.split_with(pages, fn p ->
        DateTime.compare(p.last_modified, target) != :eq or p.pages != total
      end)

    cond do
      stale == [] and length(pages) == total ->
        {:ok, pages}

      attempt >= GameRules.get(:page_retries) ->
        {:error, :inconsistent}

      true ->
        refetch(ctx, stale, fresh, etags, table, attempt)
    end
  end

  defp refetch(ctx, stale, fresh, etags, table, attempt) do
    Enum.reduce_while(stale, {:ok, fresh}, fn %{page: page}, {:ok, acc} ->
      delete_page(table, page)

      case fetch_page(ctx, page, etags, table) do
        {:ok, result} -> {:cont, {:ok, [result | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, pages} -> ensure_consistent(ctx, pages, etags, table, attempt + 1)
      error -> error
    end
  end

  defp delete_page(table, page) do
    pos = Order.page_position()
    :ets.select_delete(table, [{:"$1", [{:==, {:element, pos, :"$1"}, page}], [true]}])
  end

  # Las páginas 304 no traen cuerpo: sus filas se copian de la generación vigente en una
  # sola pasada sobre la tabla anterior.
  defp copy_not_modified(pages, previous, table) do
    not_modified = for %{status: 304, page: page} <- pages, into: MapSet.new(), do: page

    if MapSet.size(not_modified) > 0 do
      :ets.foldl(&copy_row(&1, &2, not_modified, table), :ok, previous.tid)
    end

    :ok
  end

  defp copy_row(row, :ok, pages, table) do
    if MapSet.member?(pages, Order.page(row)), do: :ets.insert(table, row)
    :ok
  end

  defp build_meta(pages, table, started) do
    first = Enum.find(pages, &(&1.page == 1))

    sells =
      :ets.select_count(table, [
        {{{:_, :sell, :_, :_}, :_, :_, :_, :_, :_, :_, :_, :_}, [], [true]}
      ])

    orders = :ets.info(table, :size)

    %{
      last_modified: first.last_modified,
      expires: pages |> Enum.map(& &1.expires) |> Enum.reject(&is_nil/1) |> Enum.min(DateTime),
      pages: first.pages,
      page_etags: for(%{page: p, etag: e} <- pages, e != nil, into: %{}, do: {p, e}),
      orders: orders,
      sell_orders: sells,
      buy_orders: orders - sells,
      bytes: :ets.info(table, :memory) * :erlang.system_info(:wordsize),
      not_modified_pages: Enum.count(pages, &(&1.status == 304)),
      duration_ms: System.monotonic_time(:millisecond) - started
    }
  end
end
