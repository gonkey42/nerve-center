defmodule NerveCenter.Messages.DeviceSnapshotUpdated do
  @enforce_keys [:device_id, :snapshot, :emitted_at]
  defstruct [:device_id, :snapshot, :emitted_at]
end

defmodule NerveCenter.Messages.SourceSnapshotUpdated do
  @enforce_keys [:device_id, :source, :source_snapshot, :emitted_at]
  defstruct [:device_id, :source, :source_snapshot, :emitted_at]
end

defmodule NerveCenter.Messages.AppHealthUpdated do
  @enforce_keys [:health, :emitted_at]
  defstruct [:health, :emitted_at]
end
