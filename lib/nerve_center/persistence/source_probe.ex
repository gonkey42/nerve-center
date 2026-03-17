defmodule NerveCenter.Persistence.SourceProbe do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}

  schema "source_probes" do
    field :device_id, :string
    field :source, :string
    field :probe_data, :map
    field :probed_at, :utc_datetime_usec
  end
end
