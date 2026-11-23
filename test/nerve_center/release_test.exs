defmodule NerveCenter.ReleaseTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias NerveCenter.Release

  @moduletag :tmp_dir

  defp touch(dir, name), do: File.write!(Path.join(dir, name), "x")

  defp seed_backups(dir) do
    for name <- [
          "nerve_center-20261119T080000-5Z.sqlite3",
          "nerve_center-20261121T162112-9Z.sqlite3",
          "nerve_center-20261120T101010-7Z.sqlite3",
          "nerve_center-20261121T162112-10Z.sqlite3"
        ],
        do: touch(dir, name)
  end

  defp names(dir), do: dir |> File.ls!() |> Enum.sort()

  test "keeps only the newest backup with keep 1", %{tmp_dir: dir} do
    seed_backups(dir)

    capture_log(fn -> assert Release.prune_backups(dir, 1) == 3 end)

    assert names(dir) == ["nerve_center-20261121T162112-10Z.sqlite3"]
  end

  test "respects keep 3", %{tmp_dir: dir} do
    seed_backups(dir)

    capture_log(fn -> assert Release.prune_backups(dir, 3) == 1 end)

    assert names(dir) == [
             "nerve_center-20261120T101010-7Z.sqlite3",
             "nerve_center-20261121T162112-10Z.sqlite3",
             "nerve_center-20261121T162112-9Z.sqlite3"
           ]
  end

  test "ignores files and directories that do not match", %{tmp_dir: dir} do
    seed_backups(dir)
    touch(dir, "pre-ups-merge-20261117.sqlite3")
    touch(dir, ".DS_Store")
    touch(dir, "nerve_center-20261101T000000-1Z.sqlite3.bak")
    File.mkdir_p!(Path.join(dir, "nerve_center-20261001T000000-1Z.sqlite3"))

    capture_log(fn -> Release.prune_backups(dir, 1) end)

    assert names(dir) == [
             ".DS_Store",
             "nerve_center-20261001T000000-1Z.sqlite3",
             "nerve_center-20261101T000000-1Z.sqlite3.bak",
             "nerve_center-20261121T162112-10Z.sqlite3",
             "pre-ups-merge-20261117.sqlite3"
           ]
  end

  test "does nothing and does not raise when the directory is missing", %{tmp_dir: dir} do
    missing = Path.join(dir, "nope")

    log = capture_log(fn -> assert Release.prune_backups(missing, 1) == 0 end)

    assert log =~ "Could not list backup dir"
    refute File.exists?(missing)
  end

  test "invalid keep values fall back to 1", %{tmp_dir: dir} do
    for keep <- [0, -2, nil, "3", 2.5] do
      seed_backups(dir)
      capture_log(fn -> Release.prune_backups(dir, keep) end)
      assert names(dir) == ["nerve_center-20261121T162112-10Z.sqlite3"]
      File.rm_rf!(dir)
      File.mkdir_p!(dir)
    end
  end
end
