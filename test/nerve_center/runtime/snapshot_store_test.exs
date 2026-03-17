defmodule NerveCenter.Runtime.SnapshotStoreTest do
  use ExUnit.Case, async: true

  alias NerveCenter.Runtime.SnapshotStore

  test "seeds unknown snapshot for configured device" do
    snapshot = SnapshotStore.snapshot(:stig)

    assert snapshot.device_id == :stig
    assert snapshot.status == :unknown
    assert snapshot.metrics == %{}
    assert snapshot.sources == %{}
  end
end
