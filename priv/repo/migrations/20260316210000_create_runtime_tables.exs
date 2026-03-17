defmodule NerveCenter.Repo.Migrations.CreateRuntimeTables do
  use Ecto.Migration

  def change do
    create table(:device_samples) do
      add :device_id, :string, null: false
      add :source, :string, null: false
      add :metric_name, :string, null: false
      add :metric_value, :float, null: false
      add :recorded_at, :utc_datetime_usec, null: false
    end

    create index(:device_samples, [:device_id, :recorded_at])

    create table(:device_events) do
      add :device_id, :string, null: false
      add :source, :string, null: false
      add :event_type, :string, null: false
      add :message, :text, null: false
      add :recorded_at, :utc_datetime_usec, null: false
    end

    create index(:device_events, [:device_id, :recorded_at])

    create table(:source_probes) do
      add :device_id, :string, null: false
      add :source, :string, null: false
      add :probe_data, :map, null: false
      add :probed_at, :utc_datetime_usec, null: false
    end

    create index(:source_probes, [:device_id, :probed_at])

    create table(:device_hourly_rollups) do
      add :device_id, :string, null: false
      add :source, :string, null: false
      add :metric_name, :string, null: false
      add :avg_value, :float, null: false
      add :min_value, :float, null: false
      add :max_value, :float, null: false
      add :sample_count, :integer, null: false
      add :bucket_start_at, :utc_datetime_usec, null: false
    end

    create index(:device_hourly_rollups, [:device_id, :bucket_start_at])
  end
end
