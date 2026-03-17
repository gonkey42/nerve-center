defmodule NerveCenter.Runtime.Health do
  @moduledoc false

  alias NerveCenter.Repo
  alias NerveCenter.Runtime.AppHealth
  alias NerveCenter.Runtime.PersistenceWriter

  def checks do
    %{
      repo: repo_alive?(),
      persistence_writer: writer_alive?(),
      migration: AppHealth.migration_success?()
    }
  end

  def healthy? do
    checks()
    |> Map.values()
    |> Enum.all?()
  end

  defp repo_alive? do
    match?({:ok, _}, Repo.query("SELECT 1"))
  rescue
    _error -> false
  end

  defp writer_alive? do
    Process.alive?(Process.whereis(PersistenceWriter))
  rescue
    ArgumentError -> false
  end
end
