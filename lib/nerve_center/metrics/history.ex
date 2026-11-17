defmodule NerveCenter.Metrics.History do
  @moduledoc false

  import Ecto.Query

  alias NerveCenter.Persistence.DeviceSample
  alias NerveCenter.Repo

  def recent_points(device_id, metric_id, limit \\ 36) do
    metric_name = Atom.to_string(metric_id)

    DeviceSample
    |> where([sample], sample.device_id == ^Atom.to_string(device_id))
    |> where([sample], sample.metric_name == ^metric_name)
    |> order_by([sample], desc: sample.recorded_at)
    |> limit(^limit)
    |> select([sample], %{value: sample.metric_value, at: sample.recorded_at})
    |> Repo.all()
    |> Enum.reverse()
  end

  def energy_totals(device_id, metric_id, current_value \\ nil, now \\ DateTime.utc_now()) do
    %{
      hour:
        energy_kwh(device_id, metric_id, DateTime.add(now, -3_600, :second), current_value, now),
      day:
        energy_kwh(device_id, metric_id, DateTime.add(now, -86_400, :second), current_value, now),
      week:
        energy_kwh(
          device_id,
          metric_id,
          DateTime.add(now, -7 * 86_400, :second),
          current_value,
          now
        ),
      month:
        energy_kwh(
          device_id,
          metric_id,
          DateTime.add(now, -30 * 86_400, :second),
          current_value,
          now
        ),
      year:
        energy_kwh(
          device_id,
          metric_id,
          DateTime.add(now, -365 * 86_400, :second),
          current_value,
          now
        )
    }
  end

  defp energy_kwh(device_id, metric_id, from, current_value, now) do
    points =
      device_id
      |> watt_points(metric_id, from, now)
      |> include_current_point(current_value, now)

    points
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce(0.0, fn [%{value: watts, at: start_at}, %{at: end_at}], acc ->
      hours = max(DateTime.diff(end_at, start_at, :second), 0) / 3_600
      acc + watts * hours / 1_000
    end)
  end

  defp watt_points(device_id, metric_id, from, now) do
    metric_name = Atom.to_string(metric_id)
    device_id = Atom.to_string(device_id)

    before_window =
      DeviceSample
      |> where([sample], sample.device_id == ^device_id)
      |> where([sample], sample.metric_name == ^metric_name)
      |> where([sample], sample.recorded_at < ^from)
      |> order_by([sample], desc: sample.recorded_at)
      |> limit(1)
      |> select([sample], %{value: sample.metric_value, at: ^from})
      |> Repo.all()

    in_window =
      DeviceSample
      |> where([sample], sample.device_id == ^device_id)
      |> where([sample], sample.metric_name == ^metric_name)
      |> where([sample], sample.recorded_at >= ^from)
      |> where([sample], sample.recorded_at <= ^now)
      |> order_by([sample], asc: sample.recorded_at)
      |> select([sample], %{value: sample.metric_value, at: sample.recorded_at})
      |> Repo.all()

    before_window ++ in_window
  end

  defp include_current_point(points, nil, _now), do: points

  defp include_current_point([], current_value, now) when is_number(current_value) do
    [%{value: current_value, at: now}]
  end

  defp include_current_point(points, current_value, now) when is_number(current_value) do
    points ++ [%{value: current_value, at: now}]
  end
end
