defmodule Eth.Release do
  @moduledoc """
  Tareas de la release sin Mix (RNF-10.3, RNF-10.7): las migraciones corren solas en cada
  arranque de la imagen de producción (`bin/migrate`, ver `Dockerfile`), así una versión
  nueva actualiza la base sin pasos manuales ni pérdida de datos.

  Implementa: RNF-10.3, RNF-10.7.
  """
  @app :eth

  @doc "Aplica las migraciones pendientes de todos los repos."
  @spec migrate() :: :ok
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end

  @doc "Revierte un repo hasta la versión indicada (uso manual, ante un problema)."
  @spec rollback(module(), integer()) :: :ok
  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
    :ok
  end

  defp repos, do: Application.fetch_env!(@app, :ecto_repos)

  defp load_app do
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
