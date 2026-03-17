defmodule NerveCenter.Persistence.DeviceEvent do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}

  schema "device_events" do
    field :device_id, :string
    field :source, :string
    field :event_type, :string
    field :message, :string
    field :recorded_at, :utc_datetime_usec
  end
end
