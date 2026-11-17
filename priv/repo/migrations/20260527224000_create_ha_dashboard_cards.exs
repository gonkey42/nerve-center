defmodule NerveCenter.Repo.Migrations.CreateHaDashboardCards do
  use Ecto.Migration

  def change do
    create table(:ha_dashboard_cards) do
      add :device_id, :string, null: false
      add :entity_id, :string, null: false
      add :title, :string, null: false
      add :card_type, :string, null: false
      add :size, :string, null: false, default: "medium"
      add :position, :integer, null: false
      add :config, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:ha_dashboard_cards, [:device_id, :position])
    create unique_index(:ha_dashboard_cards, [:device_id, :entity_id])
  end
end
