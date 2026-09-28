defmodule EthWeb.HealthController do
  @moduledoc """
  Endpoints de salud para healthchecks de Docker y monitoreo.

  - `GET /health` (liveness): el proceso web responde.
  - `GET /ready` (readiness): las dependencias necesarias están disponibles. Por ahora
    verifica la base de datos; en F2 se suman el SDE y el grafo de navegación.

  Implementa: RNF-9.4.
  """
  use EthWeb, :controller

  alias Ecto.Adapters.SQL

  @doc "Liveness: responde siempre que el endpoint esté vivo."
  @spec health(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def health(conn, _params), do: json(conn, %{status: "ok"})

  @doc "Readiness: 200 si todas las comprobaciones pasan, 503 si alguna falla."
  @spec ready(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def ready(conn, _params) do
    checks = %{database: database_check()}
    ready? = Enum.all?(checks, fn {_name, status} -> status == "ok" end)

    conn
    |> put_status(if ready?, do: :ok, else: :service_unavailable)
    |> json(%{status: if(ready?, do: "ok", else: "error"), checks: checks})
  end

  defp database_check do
    case SQL.query(Eth.Repo, "SELECT 1", []) do
      {:ok, _result} -> "ok"
      {:error, _reason} -> "error"
    end
  end
end
