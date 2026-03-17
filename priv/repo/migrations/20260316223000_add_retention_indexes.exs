defmodule NerveCenter.Repo.Migrations.AddRetentionIndexes do
  use Ecto.Migration

  def change do
    create index(:device_samples, [:recorded_at])
    create index(:device_events, [:recorded_at])
    create index(:source_probes, [:probed_at])
    create index(:device_hourly_rollups, [:bucket_start_at])
  end
end
