defmodule Eth.Esi.Client do
  @moduledoc """
  Cliente HTTP único de ESI (RF-1.1). Ningún otro módulo habla con ESI directamente:
  las rutas se exponen como funciones en `Eth.Esi`.

  - Envía `User-Agent` descriptivo (RNF-3.1), `X-Compatibility-Date` e `If-None-Match`.
  - Consulta el presupuesto antes de cada request y lo actualiza con cada respuesta.
  - Emite `[:eth, :esi, :request]` por request (duración, status, grupo, 304).
  - Sin reintentos automáticos: el backoff lo deciden los procesos que llaman (RF-1.7).

  Implementa: RF-1.1, RNF-3.1, RNF-3.2, RNF-3.3, RNF-9.1.
  """

  alias Eth.Esi.{Budget, Response}

  @repo_url "https://github.com/benabhi/eth"

  @type error ::
          {:paused, DateTime.t()}
          | {:rate_limited, DateTime.t()}
          | {:http, Response.t()}
          | {:transport, Exception.t()}

  @type opts :: [
          params: keyword(),
          etag: String.t() | nil,
          token: String.t() | nil,
          character_id: pos_integer() | nil,
          group: String.t() | nil
        ]

  @doc "GET a una ruta de ESI (p. ej. `/markets/10000002/orders`)."
  @spec get(String.t(), opts()) :: {:ok, Response.t()} | {:error, error()}
  def get(path, opts \\ []), do: request(:get, path, nil, opts)

  @doc "POST con cuerpo JSON (p. ej. `/universe/names`)."
  @spec post(String.t(), term(), opts()) :: {:ok, Response.t()} | {:error, error()}
  def post(path, json, opts \\ []), do: request(:post, path, json, opts)

  defp request(method, path, json, opts) do
    character_id = opts[:character_id]

    with :ok <- Budget.check(opts[:group], character_id) do
      started = System.monotonic_time()

      result = Req.request(base_request(), request_options(method, path, json, opts))

      duration_ms =
        System.convert_time_unit(System.monotonic_time() - started, :native, :millisecond)

      handle_result(result, path, duration_ms, character_id)
    end
  end

  defp handle_result({:ok, %Req.Response{} = req_resp}, path, duration_ms, character_id) do
    resp = Response.from_req(req_resp, duration_ms)
    Budget.record(resp, character_id)
    emit_telemetry(path, resp)

    if Response.ok?(resp), do: {:ok, resp}, else: {:error, {:http, resp}}
  end

  defp handle_result({:error, exception}, path, duration_ms, _character_id) do
    :telemetry.execute(
      [:eth, :esi, :request],
      %{duration_ms: duration_ms},
      %{path: path, status: :transport_error, group: nil, not_modified: false}
    )

    {:error, {:transport, exception}}
  end

  defp emit_telemetry(path, %Response{} = resp) do
    :telemetry.execute(
      [:eth, :esi, :request],
      %{duration_ms: resp.duration_ms},
      %{
        path: path,
        status: resp.status,
        group: resp.rate_limit && resp.rate_limit.group,
        not_modified: resp.status == 304
      }
    )
  end

  defp base_request do
    config = Application.get_env(:eth, __MODULE__, [])

    [
      base_url: Keyword.fetch!(config, :base_url),
      retry: false,
      receive_timeout: Keyword.get(config, :receive_timeout, 30_000),
      headers: [
        {"user-agent", user_agent(config[:contact])},
        {"x-compatibility-date", Keyword.fetch!(config, :compatibility_date)}
      ]
    ]
    |> Keyword.merge(Keyword.get(config, :req_options, finch: [name: Eth.Finch]))
    |> Req.new()
  end

  defp request_options(method, path, json, opts) do
    base = [
      method: method,
      url: path,
      params: opts[:params] || [],
      headers: request_headers(opts)
    ]

    if json == nil, do: base, else: Keyword.put(base, :json, json)
  end

  defp request_headers(opts) do
    Enum.reject(
      [
        opts[:etag] && {"if-none-match", opts[:etag]},
        opts[:token] && {"authorization", "Bearer " <> opts[:token]}
      ],
      &is_nil/1
    )
  end

  @doc """
  User-Agent de lo más específico a lo más general, con contacto (RNF-3.1).
  """
  @spec user_agent(String.t() | nil) :: String.t()
  def user_agent(contact) do
    app = "EVETradeHunter/#{Application.spec(:eth, :vsn)}"
    about = if contact in [nil, ""], do: "(+#{@repo_url})", else: "(#{contact}; +#{@repo_url})"
    libs = "Req/#{Application.spec(:req, :vsn)} Elixir/#{System.version()}"
    Enum.join([app, about, libs], " ")
  end
end
