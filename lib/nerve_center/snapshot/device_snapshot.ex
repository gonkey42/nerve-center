defmodule NerveCenter.Snapshot.DeviceSnapshot do
  @moduledoc false

  defstruct [
    :device_id,
    :label,
    :status,
    :updated_at,
    :offline_expected,
    metrics: %{},
    sources: %{}
  ]
end
