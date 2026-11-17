defmodule NerveCenter.Metrics.HistoryTest do
  use NerveCenter.DataCase, async: false

  alias NerveCenter.Metrics.History
  alias NerveCenter.Persistence.DeviceSample
  alias NerveCenter.Repo

  test "energy_totals integrates watt samples into kWh" do
    now = ~U[2026-05-27 12:00:00.000000Z]

    Repo.insert_all(DeviceSample, [
      %{
        device_id: "ups",
        source: "nut",
        metric_name: "ups_current_load_watts",
        metric_value: 100.0,
        recorded_at: DateTime.add(now, -3_600, :second)
      },
      %{
        device_id: "ups",
        source: "nut",
        metric_name: "ups_current_load_watts",
        metric_value: 200.0,
        recorded_at: DateTime.add(now, -1_800, :second)
      }
    ])

    totals = History.energy_totals(:ups, :ups_current_load_watts, 200.0, now)

    assert_in_delta totals.hour, 0.15, 0.0001
    assert_in_delta totals.day, 0.15, 0.0001
    assert_in_delta totals.year, 0.15, 0.0001
  end
end
