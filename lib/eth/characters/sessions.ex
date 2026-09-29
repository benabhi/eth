defmodule Eth.Characters.Sessions do
  @moduledoc """
  Administración de las sesiones de personajes (RF-5.4, RF-5.10): arranque, consulta del
  contexto, registro de observadores (LiveViews) y token para acciones in-game.
  """

  alias Eth.Characters.Session

  @doc "Arranca la sesión del personaje; si ya existe y hay login nuevo, le pasa los tokens."
  @spec start(pos_integer(), Eth.Sso.login() | nil) :: :ok
  def start(id, login \\ nil) do
    case DynamicSupervisor.start_child(Eth.Characters.SessionSupervisor, {Session, {id, login}}) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, pid}} ->
        if login, do: GenServer.call(pid, {:login, login}), else: :ok

      {:error, _reason} ->
        :ok
    end
  end

  @doc "Contexto actual del personaje (`nil` si no hay sesión)."
  @spec context(pos_integer()) :: map() | nil
  def context(id), do: call(id, :context)

  @doc "Registra al proceso llamador como observador (modo activo) y devuelve el contexto."
  @spec watch(pos_integer()) :: map() | nil
  def watch(id), do: call(id, {:watch, self()})

  @doc "Access token vigente para acciones in-game."
  @spec token(pos_integer()) :: {:ok, String.t()} | {:error, term()}
  def token(id), do: call(id, :token) || {:error, :no_session}

  @doc "Detiene la sesión (al olvidar el personaje)."
  @spec stop(pos_integer()) :: :ok
  def stop(id) do
    case whereis(id) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(Eth.Characters.SessionSupervisor, pid)
    end

    :ok
  end

  # Sin el Registry (supervisor apagado, p. ej. en tests) no hay sesiones.
  defp whereis(id) do
    GenServer.whereis(Session.via(id))
  rescue
    ArgumentError -> nil
  end

  defp call(id, message) do
    case whereis(id) do
      nil -> nil
      pid -> GenServer.call(pid, message)
    end
  catch
    :exit, _ -> nil
  end
end
