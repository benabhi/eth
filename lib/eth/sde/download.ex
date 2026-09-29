defmodule Eth.Sde.Download do
  @moduledoc """
  Descarga del SDE oficial de CCP en formato JSONL (RF-2.1, ERS §6.4).

  - `latest_build/0` lee `tranquility/latest.jsonl` (registro con clave `sde`).
  - `zip/2` descarga el zip de un build directamente a disco (≈ 100 MB).
  """

  alias Eth.Esi.Client
  alias Eth.GameRules

  @doc "Número y fecha del último build publicado."
  @spec latest_build() ::
          {:ok, %{build: pos_integer(), release_date: String.t()}} | {:error, term()}
  def latest_build do
    with {:ok, %{status: 200, body: body}} <- Req.get(request(), url: "/tranquility/latest.jsonl"),
         %{"buildNumber" => build} = record <- find_sde_record(body) do
      {:ok, %{build: build, release_date: record["releaseDate"]}}
    else
      {:ok, %{status: status}} -> {:error, {:http, status}}
      {:error, exception} -> {:error, {:transport, Exception.message(exception)}}
      nil -> {:error, :no_sde_record}
    end
  end

  @doc "Descarga el zip JSONL de `build` en `dest` (archivo)."
  @spec zip(pos_integer(), Path.t()) :: :ok | {:error, term()}
  # Ruta dentro del directorio de datos + build entero; nunca entrada externa.
  # sobelow_skip ["Traversal.FileModule"]
  def zip(build, dest) when is_integer(build) do
    tmp = dest <> ".part"

    case Req.get(request(),
           url: "/tranquility/eve-online-static-data-#{build}-jsonl.zip",
           into: File.stream!(tmp),
           receive_timeout: 300_000
         ) do
      {:ok, %{status: 200}} -> File.rename(tmp, dest)
      {:ok, %{status: status}} -> {:error, {:http, status}}
      {:error, exception} -> {:error, {:transport, Exception.message(exception)}}
    end
  end

  # latest.jsonl trae un registro JSON por línea; el del SDE tiene `_key: "sde"`.
  defp find_sde_record(body) when is_binary(body) do
    body
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
    |> Enum.find(&(&1["_key"] == "sde"))
  end

  defp find_sde_record(%{"_key" => "sde"} = record), do: record
  defp find_sde_record(_body), do: nil

  defp request do
    contact = Application.get_env(:eth, Eth.Esi.Client, [])[:contact]

    [
      base_url: GameRules.get(:sde_base_url),
      headers: [{"user-agent", Client.user_agent(contact)}],
      retry: false,
      decode_body: false
    ]
    # En tests: plug de Req.Test (RNF-3.8).
    |> Keyword.merge(Application.get_env(:eth, __MODULE__, [])[:req_options] || [])
    |> Req.new()
  end
end
