defmodule NerveCenter.Repo.Migrations.AllowDuplicateHaDashboardCards do
  use Ecto.Migration

  def change do
    drop_if_exists unique_index(:ha_dashboard_cards, [:device_id, :entity_id])
    create index(:ha_dashboard_cards, [:device_id, :entity_id])
  end
end
