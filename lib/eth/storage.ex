defmodule Eth.Storage do
  @moduledoc """
  Directorio de datos regenerables (SDE procesado, matrices de ruteo, snapshots de
  mercado, replay). Vive en un volumen propio, nunca en git ni en la imagen (RNF-10.4).
  En tests se configura otro directorio (`config :eth, :data_dir`).
  """

  @doc "Directorio base de datos."
  @spec data_dir() :: Path.t()
  def data_dir,
    do: Application.get_env(:eth, :data_dir) || Path.join(:code.priv_dir(:eth), "data")

  @doc "Subdirectorio de datos (lo crea si no existe)."
  @spec path(String.t()) :: Path.t()
  # `subdir` es siempre un literal del código ("sde", "snapshots"…), nunca entrada externa.
  # sobelow_skip ["Traversal.FileModule"]
  def path(subdir) do
    dir = Path.join(data_dir(), subdir)
    File.mkdir_p!(dir)
    dir
  end
end
