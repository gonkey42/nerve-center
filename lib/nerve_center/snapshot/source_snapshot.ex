defmodule NerveCenter.Snapshot.SourceSnapshot do
  @moduledoc false

  defstruct [
    :device_id,
    :source,
    :status,
    :observed_at,
    :last_ok_at,
    :last_error_at,
    :last_error,
    :probe_data,
    :consecutive_failures,
    :backoff_ms,
    :ever_ok?,
    data: %{},
    metrics: %{}
  ]
end
