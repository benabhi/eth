defmodule Eth.Market.SnapshotsTest do
  use ExUnit.Case, async: false

  alias Eth.Market.{Snapshots, TableOwner}

  @moduletag :tmp_dir

  setup do
    start_supervised!(TableOwner)
    :ok
  end

  defp publish_sample(region_id) do
    tid = :ets.new(:eth_orders, [:ordered_set, :public])
    :ets.insert(tid, {{34, :sell, 5.0, 1}, 60_003_760, 30_000_142, 10, 1, :region, 0, 5.0, 1})

    meta = %{
      last_modified: ~U[2026-09-29 00:00:00Z],
      expires: ~U[2026-09-29 00:05:00Z],
      pages: 1,
      page_etags: %{1 => ~s("e1")},
      orders: 1
    }

    {:ok, _gen} = TableOwner.publish(tid, {:region, region_id}, meta)
    meta
  end

  test "guarda y recarga un snapshot con sus metadatos (incluidos los ETag)", %{tmp_dir: dir} do
    meta = publish_sample(10_000_002)
    entry = TableOwner.current({:region, 10_000_002})

    assert :ok = Snapshots.save(10_000_002, "The Forge", entry, dir)
    assert Snapshots.list(dir) == [{10_000_002, "The Forge"}]

    assert {:ok, tid, loaded} = Snapshots.load(10_000_002, dir)
    assert loaded.page_etags == meta.page_etags
    assert loaded.name == "The Forge"
    assert :ets.info(tid, :size) == 1
    # La tabla cargada es del proceso que la cargó (para publicarla después).
    assert :ets.info(tid, :owner) == self()
  end

  test "save_all guarda todo lo publicado", %{tmp_dir: dir} do
    publish_sample(10_000_002)
    publish_sample(10_000_043)

    assert Snapshots.save_all(%{10_000_002 => "The Forge", 10_000_043 => "Domain"}, dir) == 2
    assert Snapshots.list(dir) == [{10_000_043, "Domain"}, {10_000_002, "The Forge"}]
  end

  test "los metadatos se serializan sin átomos (decodificables al arrancar)" do
    meta = %{
      name: "The Forge",
      last_modified: ~U[2026-09-29 00:22:18Z],
      expires: ~U[2026-09-29 00:27:18Z],
      page_etags: %{1 => ~s("e1")},
      orders: 10,
      ignored_key: :x
    }

    binary = Snapshots.encode_meta(meta)
    # Solo strings, números y fechas en ISO 8601: ningún átomo en el binario.
    refute binary |> :erlang.binary_to_term() |> Map.keys() |> Enum.any?(&is_atom/1)

    assert Snapshots.decode_meta(binary) == Map.delete(meta, :ignored_key)
  end

  test "sin archivo o con metadatos corruptos no carga", %{tmp_dir: dir} do
    assert Snapshots.load(10_000_002, dir) == :error

    File.write!(Path.join(dir, "region_10000002.meta"), "basura")
    assert Snapshots.load(10_000_002, dir) == :error
    assert Snapshots.read_meta(10_000_002, dir) == nil
  end
end
