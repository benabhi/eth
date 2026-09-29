defmodule Eth.EsiStub do
  @moduledoc """
  Ayudas para simular ESI con `Req.Test` (RNF-3.8): respuestas con las cabeceras reales
  que usa el cliente (`Expires`, `Last-Modified`, `ETag`, `X-Pages`, rate limit).
  """

  import Plug.Conn

  @doc "Formatea un `DateTime` como fecha HTTP (IMF-fixdate)."
  @spec http_date(DateTime.t()) :: String.t()
  def http_date(%DateTime{} = dt), do: Calendar.strftime(dt, "%a, %d %b %Y %H:%M:%S GMT")

  @doc """
  Responde como ESI. Opciones: `:headers` (lista de `{nombre, valor}`), `:expires`,
  `:last_modified` (`DateTime`), `:etag`, `:pages`, `:rate_limit` (`{grupo, restante}`).
  """
  @spec respond(Plug.Conn.t(), non_neg_integer(), term(), keyword()) :: Plug.Conn.t()
  def respond(conn, status, body, opts \\ []) do
    headers =
      [
        opts[:expires] && {"expires", http_date(opts[:expires])},
        opts[:last_modified] && {"last-modified", http_date(opts[:last_modified])},
        opts[:etag] && {"etag", opts[:etag]},
        opts[:pages] && {"x-pages", Integer.to_string(opts[:pages])}
      ] ++ rate_limit_headers(opts[:rate_limit]) ++ Keyword.get(opts, :headers, [])

    conn =
      headers
      |> Enum.reject(&is_nil/1)
      |> Enum.reduce(conn, fn {k, v}, acc -> put_resp_header(acc, k, v) end)

    if status == 304 or body == nil do
      send_resp(conn, status, "")
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(body))
    end
  end

  defp rate_limit_headers(nil), do: []

  defp rate_limit_headers({group, remaining}) do
    [
      {"x-ratelimit-group", group},
      {"x-ratelimit-limit", "12000/15m"},
      {"x-ratelimit-remaining", Integer.to_string(remaining)},
      {"x-ratelimit-used", "2"}
    ]
  end
end
