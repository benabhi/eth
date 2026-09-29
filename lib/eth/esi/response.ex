defmodule Eth.Esi.Response do
  @moduledoc """
  Respuesta de ESI con los metadatos de caché y presupuesto ya interpretados (RF-1.1).
  """

  alias Eth.Esi.HttpDate

  @type rate_limit :: %{
          group: String.t(),
          limit: non_neg_integer(),
          window_s: pos_integer(),
          remaining: non_neg_integer(),
          used: non_neg_integer()
        }

  @type t :: %__MODULE__{
          status: non_neg_integer(),
          body: term(),
          expires: DateTime.t() | nil,
          last_modified: DateTime.t() | nil,
          etag: String.t() | nil,
          pages: pos_integer() | nil,
          rate_limit: rate_limit() | nil,
          error_limit: %{remain: non_neg_integer(), reset_s: non_neg_integer()} | nil,
          retry_after_s: non_neg_integer() | nil,
          warning: String.t() | nil,
          duration_ms: non_neg_integer()
        }

  @enforce_keys [:status]
  defstruct [
    :status,
    :body,
    :expires,
    :last_modified,
    :etag,
    :pages,
    :rate_limit,
    :error_limit,
    :retry_after_s,
    :warning,
    duration_ms: 0
  ]

  @doc "Construye la respuesta a partir de un `Req.Response`."
  @spec from_req(Req.Response.t(), non_neg_integer()) :: t()
  def from_req(%Req.Response{} = resp, duration_ms) do
    header = fn name -> resp |> Req.Response.get_header(name) |> List.first() end

    %__MODULE__{
      status: resp.status,
      body: if(resp.status == 304, do: nil, else: resp.body),
      expires: HttpDate.parse(header.("expires")),
      last_modified: HttpDate.parse(header.("last-modified")),
      etag: header.("etag"),
      pages: parse_int(header.("x-pages")),
      rate_limit: parse_rate_limit(header),
      error_limit: parse_error_limit(header),
      retry_after_s: parse_int(header.("retry-after")),
      warning: header.("warning"),
      duration_ms: duration_ms
    }
  end

  @doc "`true` para 2XX y 304 (respuestas útiles)."
  @spec ok?(t()) :: boolean()
  def ok?(%__MODULE__{status: status}), do: status in 200..299 or status == 304

  defp parse_rate_limit(header) do
    with group when is_binary(group) <- header.("x-ratelimit-group"),
         [limit, window] <- String.split(header.("x-ratelimit-limit") || "", "/"),
         {limit, ""} <- Integer.parse(limit),
         {:ok, window_s} <- parse_window(window) do
      %{
        group: group,
        limit: limit,
        window_s: window_s,
        remaining: parse_int(header.("x-ratelimit-remaining")) || limit,
        used: parse_int(header.("x-ratelimit-used")) || 0
      }
    else
      _ -> nil
    end
  end

  # Formato de ventana de ESI: "15m", "1h", "30s".
  defp parse_window(window) do
    case Integer.parse(window) do
      {n, "s"} -> {:ok, n}
      {n, "m"} -> {:ok, n * 60}
      {n, "h"} -> {:ok, n * 3600}
      _ -> :error
    end
  end

  defp parse_error_limit(header) do
    remain = parse_int(header.("x-esi-error-limit-remain"))
    reset = parse_int(header.("x-esi-error-limit-reset"))
    if remain && reset, do: %{remain: remain, reset_s: reset}
  end

  defp parse_int(nil), do: nil

  defp parse_int(value) do
    case Integer.parse(value) do
      {n, _} -> n
      :error -> nil
    end
  end
end
