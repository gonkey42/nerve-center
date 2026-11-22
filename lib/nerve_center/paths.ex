defmodule NerveCenter.Paths do
  @moduledoc false

  def db_path do
    fetch!(:db)
  end

  def backup_dir do
    fetch!(:backups)
  end

  def log_dir do
    fetch!(:log_dir)
  end

  def app_log_path do
    fetch!(:app_log)
  end

  # Number of backups to keep after a successful backup. Always at least 1.
  def backup_keep do
    case Application.get_env(:nerve_center, :backup_keep, 1) do
      keep when is_integer(keep) and keep >= 1 -> keep
      _ -> 1
    end
  end

  def backup_path(suffix \\ timestamp_suffix()) do
    Path.join(backup_dir(), "nerve_center-#{suffix}.sqlite3")
  end

  defp paths do
    Application.fetch_env!(:nerve_center, :paths)
  end

  defp fetch!(key) do
    paths = paths()

    cond do
      is_map(paths) -> Map.fetch!(paths, key)
      Keyword.keyword?(paths) -> Keyword.fetch!(paths, key)
      true -> raise ArgumentError, "unexpected path configuration: #{inspect(paths)}"
    end
  end

  defp timestamp_suffix do
    timestamp =
      DateTime.utc_now()
      |> Calendar.strftime("%Y%m%dT%H%M%S")

    "#{timestamp}-#{System.unique_integer([:positive])}Z"
  end
end
