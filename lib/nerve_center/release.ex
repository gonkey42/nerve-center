defmodule NerveCenter.Release do
  @moduledoc false

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
