defmodule NerveCenter.Release do
  @moduledoc false

  require Logger

  alias Ecto.Migrator
  alias NerveCenter.Paths
  alias NerveCenter.Runtime.BootLog

  @retry_delays [1_000, 2_000, 5_000]
  @migration_key {__MODULE__, :last_migration}

  def migrate do
    File.mkdir_p!(Path.dirname(Paths.db_path()))
    File.mkdir_p!(Paths.backup_dir())
    do_migrate(@retry_delays)
  end

  def last_migration_result do
    :persistent_term.get(@migration_key, %{status: :unknown, at: nil, message: nil})
  end

  defp do_migrate(retry_delays) do
    migrations_path = Application.app_dir(:nerve_center, "priv/repo/migrations")

    case run_migrations(migrations_path, retry_delays) do
      :ok ->
        result = %{status: :ok, at: DateTime.utc_now(), message: "ok"}
        :persistent_term.put(@migration_key, result)
        result

      {:retry, _error, [delay | remaining]} ->
        Process.sleep(delay)
        do_migrate(remaining)

      {:retry, error, []} ->
        fail_boot("migration busy after retries: #{Exception.message(error)}")

      {:error, error} ->
        fail_boot("migration failed: #{Exception.message(error)}")
    end
  end

  defp run_migrations(migrations_path, retry_delays) do
    case Migrator.with_repo(NerveCenter.Repo, fn repo ->
           maybe_backup(repo)
           Migrator.run(repo, migrations_path, :up, all: true)
         end) do
      {:ok, _started_apps, _result} ->
        :ok

      {:error, error} ->
        classify_error(error, retry_delays)
    end
  rescue
    error -> classify_error(error, retry_delays)
  end

  defp maybe_backup(repo) do
    if File.exists?(Paths.db_path()) do
      backup_path = Paths.backup_path()
      escaped_backup_path = String.replace(backup_path, "'", "''")
      Ecto.Adapters.SQL.query!(repo, "VACUUM INTO '#{escaped_backup_path}'", [])

      if valid_backup?(backup_path) do
        prune_backups(Paths.backup_dir(), Paths.backup_keep())
      else
        Logger.warning("Backup #{Path.basename(backup_path)} is missing or empty, skipping prune")
      end
    end
  end

  defp valid_backup?(path) do
    match?({:ok, %File.Stat{type: :regular, size: size}} when size > 0, File.stat(path))
  end

  @doc false
  # Deletes all but the newest `keep` files named nerve_center-*.sqlite3 in `dir`.
  # Other files are never touched. Never raises, so it cannot block app start.
  # A `keep` below 1 or not an integer is treated as 1.
  def prune_backups(dir, keep) do
    keep = if is_integer(keep) and keep >= 1, do: keep, else: 1

    case File.ls(dir) do
      {:ok, names} ->
        removed =
          names
          |> Enum.filter(&backup_file?(dir, &1))
          |> Enum.sort_by(&backup_sort_key/1, :desc)
          |> Enum.drop(keep)
          |> Enum.count(&remove_backup(dir, &1))

        Logger.info("Removed #{removed} old database backup(s), keeping the newest #{keep}")
        removed

      {:error, reason} ->
        Logger.warning("Could not list backup dir for pruning: #{:file.format_error(reason)}")
        0
    end
  rescue
    error ->
      Logger.warning("Backup pruning failed: #{Exception.message(error)}")
      0
  end

  defp backup_file?(dir, name) do
    String.starts_with?(name, "nerve_center-") and String.ends_with?(name, ".sqlite3") and
      match?({:ok, %File.Stat{type: :regular}}, File.lstat(Path.join(dir, name)))
  end

  # Names look like nerve_center-20261121T162112-123Z.sqlite3. Sort by the
  # timestamp, then by the unique integer, then by name.
  defp backup_sort_key(name) do
    case Regex.run(~r/^nerve_center-(\d{8}T\d{6})-(\d+)Z\.sqlite3$/, name) do
      [_, timestamp, unique] -> {timestamp, String.to_integer(unique), name}
      nil -> {"", 0, name}
    end
  end

  defp remove_backup(dir, name) do
    case File.rm(Path.join(dir, name)) do
      :ok ->
        true

      {:error, reason} ->
        Logger.warning("Could not remove old backup #{name}: #{:file.format_error(reason)}")
        false
    end
  end

  defp classify_error(error, retry_delays) do
    if sqlite_busy?(error) do
      {:retry, error, retry_delays}
    else
      {:error, error}
    end
  end

  defp sqlite_busy?(%Exqlite.Error{message: message}) do
    String.contains?(message, "SQLITE_BUSY") or
      String.contains?(message, "database is locked") or
      String.contains?(message, "database table is locked")
  end

  defp sqlite_busy?(%RuntimeError{message: message}) do
    sqlite_busy_message?(message)
  end

  defp sqlite_busy?(%DBConnection.ConnectionError{message: message}) do
    sqlite_busy_message?(message)
  end

  defp sqlite_busy?(_error), do: false

  defp sqlite_busy_message?(message) do
    String.contains?(message, "SQLITE_BUSY") or
      String.contains?(message, "database is locked")
  end

  defp fail_boot(message) do
    BootLog.append!(message)
    raise RuntimeError, message
  end
end
