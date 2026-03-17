defmodule NerveCenter.Persistence.DeviceSample do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}

  schema "device_samples" do
    field :device_id, :string
    field :source, :string
    field :metric_name, :string
    field :metric_value, :float
    field :recorded_at, :utc_datetime_usec
  end
end
