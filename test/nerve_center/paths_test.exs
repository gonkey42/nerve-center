defmodule NerveCenter.PathsTest do
  use ExUnit.Case, async: true

  alias NerveCenter.Paths

  test "backup_path generates unique filenames on consecutive calls" do
    first = Paths.backup_path()
    second = Paths.backup_path()

    refute first == second
    assert String.ends_with?(first, ".sqlite3")
    assert String.ends_with?(second, ".sqlite3")
  end
end
