defmodule NerveCenter.Persistence.HADashboardCard do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @card_types ["entity", "gauge", "sensor", "weather"]
  @sizes ["small", "medium", "wide"]

  schema "ha_dashboard_cards" do
    field :device_id, :string
    field :entity_id, :string
    field :title, :string
    field :card_type, :string
    field :size, :string
    field :position, :integer
    field :config, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(card, attrs) do
    card
    |> cast(attrs, [:device_id, :entity_id, :title, :card_type, :size, :position, :config])
    |> validate_required([:device_id, :entity_id, :title, :card_type, :size, :position])
    |> validate_inclusion(:card_type, @card_types)
    |> validate_inclusion(:size, @sizes)
  end
end
