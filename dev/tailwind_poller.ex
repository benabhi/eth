defmodule Eth.Dev.TailwindPoller do
  @moduledoc """
  Watcher de Tailwind por polling, solo para desarrollo.

  Tailwind v4 eliminó `--poll` y su modo `--watch` depende de eventos inotify, que no
  llegan al contenedor cuando el código vive en NTFS (Windows) montado por bind mount.
  Este watcher compara los mtimes de `assets/` y `lib/` cada `interval` ms y recompila
  el CSS cuando algo cambia. Se activa con `ETH_FS_POLL=true`.

  Implementa: RNF-11.2.
  """

  @globs ["assets/**/*.{css,js,ts}", "lib/**/*.{ex,heex}"]

  @doc "Compila el CSS una vez y luego recompila ante cada cambio detectado."
  @spec run(atom(), pos_integer()) :: no_return()
  def run(profile, interval \\ 1_000) do
    Tailwind.install_and_run(profile, [])
    loop(profile, interval, snapshot())
  end

  defp loop(profile, interval, previous) do
    Process.sleep(interval)
    current = snapshot()

    if current != previous do
      Tailwind.run(profile, [])
    end

    loop(profile, interval, current)
  end

  # Un archivo puede borrarse entre el wildcard y el stat: se ignora en vez de fallar
  # (su desaparición cambia el mapa y dispara la recompilación igual).
  defp snapshot do
    @globs
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.flat_map(fn path ->
      case File.stat(path) do
        {:ok, %File.Stat{mtime: mtime}} -> [{path, mtime}]
        {:error, _reason} -> []
      end
    end)
    |> Map.new()
  end
end
