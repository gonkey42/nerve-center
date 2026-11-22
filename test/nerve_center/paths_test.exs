defmodule NerveCenter.PathsTest do
  use ExUnit.Case, async: false

  alias NerveCenter.Paths

  test "backup_path generates unique filenames on consecutive calls" do
    first = Paths.backup_path()
    second = Paths.backup_path()

    refute first == second
    assert String.ends_with?(first, ".sqlite3")
    assert String.ends_with?(second, ".sqlite3")
  end

  test "backup_keep defaults to 1 and never goes below 1" do
    original = Application.fetch_env(:nerve_center, :backup_keep)

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:nerve_center, :backup_keep, value)
        :error -> Application.delete_env(:nerve_center, :backup_keep)
      end
    end)

    Application.delete_env(:nerve_center, :backup_keep)
    assert Paths.backup_keep() == 1

    Application.put_env(:nerve_center, :backup_keep, 3)
    assert Paths.backup_keep() == 3

    Application.put_env(:nerve_center, :backup_keep, 0)
    assert Paths.backup_keep() == 1
  end
end
