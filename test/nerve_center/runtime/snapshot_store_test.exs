defmodule NerveCenter.Runtime.SnapshotStoreTest do
  use ExUnit.Case, async: true

  alias NerveCenter.Runtime.SnapshotStore
  alias NerveCenter.Snapshot.SourceSnapshot

  test "seeds unknown snapshot for configured device" do
    snapshot = SnapshotStore.snapshot(:stig)

    assert snapshot.device_id == :stig
    assert snapshot.status == :unknown
    assert snapshot.metrics == %{}

    assert Enum.all?(snapshot.sources, fn
             {source_name,
              %SourceSnapshot{
                device_id: :stig,
                source: source_name,
                status: :unknown,
                metrics: metrics
              }} ->
               metrics == %{}
           end)
  end
end
