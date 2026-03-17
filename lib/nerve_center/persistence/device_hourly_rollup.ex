defmodule NerveCenter.Persistence.DeviceHourlyRollup do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}

  schema "device_hourly_rollups" do
    field :device_id, :string
    field :source, :string
    field :metric_name, :string
    field :avg_value, :float
    field :min_value, :float
    field :max_value, :float
    field :sample_count, :integer
    field :bucket_start_at, :utc_datetime_usec
  end
end
