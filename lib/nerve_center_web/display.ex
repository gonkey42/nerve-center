defmodule NerveCenterWeb.Display do
  @moduledoc false

  def percent(nil), do: "-"
  def percent(value) when is_number(value), do: "#{Float.round(value * 100, 1)}%"

  def bytes(nil), do: "-"
  def bytes(value) when value < 1024, do: "#{round(value)} B"
  def bytes(value) when value < 1_048_576, do: "#{Float.round(value / 1024, 1)} KiB"
  def bytes(value) when value < 1_073_741_824, do: "#{Float.round(value / 1_048_576, 1)} MiB"
  def bytes(value), do: "#{Float.round(value / 1_073_741_824, 1)} GiB"

  def throughput(value), do: "#{bytes(value)}/s"

  def duration(nil), do: "-"

  def duration(seconds) do
    total = round(seconds)
    days = div(total, 86_400)
    hours = div(rem(total, 86_400), 3_600)
    minutes = div(rem(total, 3_600), 60)

    cond do
      days > 0 -> "#{days}d #{hours}h"
      hours > 0 -> "#{hours}h #{minutes}m"
      true -> "#{minutes}m"
    end
  end

  def status_class(:ok), do: "bg-emerald-500/20 text-emerald-300 ring-emerald-400/30"
  def status_class(:degraded), do: "bg-amber-500/20 text-amber-200 ring-amber-400/30"
  def status_class(:offline), do: "bg-rose-500/20 text-rose-200 ring-rose-400/30"
  def status_class(:unknown), do: "bg-stone-700/40 text-stone-200 ring-stone-500/40"
  def status_class(:stale), do: status_class(:degraded)
  def status_class(:error), do: status_class(:offline)
end
