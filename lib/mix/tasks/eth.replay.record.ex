defmodule Mix.Tasks.Eth.Replay.Record do
  @shortdoc "Graba los snapshots actuales para el modo Replay"

  @moduledoc """
  Copia los snapshots de mercado guardados por el servidor (`priv/data/snapshots/`) al
  directorio del modo Replay (`priv/data/replay/`), para desarrollar y medir sin ESI
  (RF-1.11).

      mix eth.replay.record
      mix eth.replay.record --regions 10000002,10000043

  También copia las kills de la ventana del radar (`priv/data/threat/kills.json`).
  Los snapshots se guardan cada 10 minutos y al apagar el servidor. Después se usa con
  `ETH_DATA_SOURCE=replay`.
  """
  use Mix.Task

  alias Eth.Market.Snapshots
  alias Eth.Threat.Radar

  @impl true
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: [regions: :string])
    Mix.Task.run("app.config")

    source = Snapshots.dir(:snapshots)
    target = Snapshots.dir(:replay)
    regions = Snapshots.list(source) |> filter(opts[:regions])

    if regions == [] do
      Mix.raise("No hay snapshots en #{source}. Dejá correr el servidor al menos un ciclo.")
    end

    File.mkdir_p!(target)

    for {id, name} <- regions, ext <- [".ets", ".meta"] do
      File.cp!(Path.join(source, "region_#{id}#{ext}"), Path.join(target, "region_#{id}#{ext}"))
      if ext == ".meta", do: Mix.shell().info("  #{name} (#{id})")
    end

    Mix.shell().info("#{length(regions)} regiones grabadas en #{target}")
    record_kills()
  end

  # Kills de la ventana del radar (las guarda el servidor cada 30 s), para el feed Replay.
  defp record_kills do
    source = Radar.kills_file("threat")

    if File.exists?(source) do
      File.cp!(source, Radar.kills_file("replay"))
      Mix.shell().info("Kills del radar grabadas")
    else
      Mix.shell().info("Sin kills del radar para grabar (el feed todavía no entregó datos)")
    end
  end

  defp filter(regions, nil), do: regions

  defp filter(regions, ids) do
    wanted = ids |> String.split(",", trim: true) |> Enum.map(&String.to_integer(String.trim(&1)))
    Enum.filter(regions, fn {id, _} -> id in wanted end)
  end
end
