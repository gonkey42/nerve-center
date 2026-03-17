defmodule NerveCenter.Runtime.SnapshotStoreTest do
  use ExUnit.Case, async: true

  alias NerveCenter.Runtime.SnapshotStore

  test "seeds unknown snapshot for configured device" do
    snapshot = SnapshotStore.snapshot(:rosie)

    assert snapshot.device_id == :rosie
    assert snapshot.status == :unknown
    assert snapshot.metrics == %{}
    assert snapshot.sources == %{}
  end
end
